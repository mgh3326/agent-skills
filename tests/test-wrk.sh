#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
HERDR="$ROOT/tests/fixtures/herdr"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
ARBITER="$ROOT/bin/arbiter"
TMP="$(mktemp -d)"
# 이 스위트가 띄운 sleep 은 환경(ARBITER_INBOX_ROOT 등)에 $TMP 를 달고 있다 —
# run 소속을 정확히 식별하므로 다른 스위트의 sleep 은 절대 매치되지 않는다.
suite_sleep_orphans() {
  local pid
  while IFS= read -r pid; do
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qF -- "$TMP"; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -x sleep 2>/dev/null || true)
}
# spawn 이 띄운 센티널은 nohup 으로 분리되어 있다 — 스위트가 끝나면 그 자식
# (interval 동안 살아남는 sleep)과 함께 거둔다. 센티널만 죽이면 sleep 이 orphan
# 으로 남아 잡 디렉토리의 flock fd 를 interval 내내 잡고 있는다(#637, #682).
cleanup() {
  local pidfile pid child orphan escaped deadline
  while IFS= read -r pidfile; do
    [[ -s "$pidfile" ]] || continue
    read -r pid <"$pidfile" || continue
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # STOP 으로 얼려 자식 목록과 kill 사이에 새 sleep 을 fork 하지 못하게 하고,
    # 자식은 pid 로만 죽인다 — 이름 기반 pkill 은 타 스위트 프로세스를 친다.
    kill -STOP "$pid" 2>/dev/null || true
    while IFS= read -r child; do
      kill "$child" 2>/dev/null || true
    done < <(pgrep -P "$pid" 2>/dev/null || true)
    kill "$pid" 2>/dev/null || true
    kill -CONT "$pid" 2>/dev/null || true
  done < <(find "$TMP" -name 'completion-sentinel.pid' 2>/dev/null)
  # 실행 중간에 센티널이 먼저 죽은 경우 sleep 은 이미 init 아래로 reparent 됐다 —
  # 환경 태그로 여전히 우리 것임을 식별해 거둔다.
  deadline=$(( $(date +%s) + 5 ))
  while :; do
    escaped="$(suite_sleep_orphans)"
    if [[ -z "$escaped" ]]; then break; fi
    for orphan in $escaped; do kill "$orphan" 2>/dev/null || true; done
    if (( $(date +%s) >= deadline )); then break; fi
    sleep 0.2
  done
  # kill만으로는 부족하다 — TERM 받은 프로세스가 아직 쓰기 중일 수 있고,
  # refresh_quota_pool 의 분리된 supervisor(`python3 - <scopefuel> …` ->
  # setsid -> `scopefuel refresh <pool> --background`)는 pidfile 없이
  # WRK_REFRESH_LOG 를 덧붙인다. 죽인 뒤 rm 이 디렉터리를 걸으면서 재생성된
  # 엔트리를 만나면 rm -rf 가 "Directory not empty" 로 실패한다(CI runs
  # 36283072131/36288704921). 이 스위트가 띄운 모든 detached 프로세스는
  # $TMP 아래를 가리키는 export 된 env(XDG_DATA_HOME·ARBITER_INBOX_ROOT·
  # HK_STATE·fixture 로그 경로)를 물려받으므로 전체 ps 스캔이 정확히 이 run
  # 에만 매치된다. $$ 와 현재 자식들을 제외해 파이프라인 자기 자신과
  # 부모(wrk heavy·CI bash)를 치지 않는다.
  local snap stray i
  for ((i = 0; i < 100; i++)); do
    snap="$(exec ps axeww -o pid= -o ppid= -o command= 2>/dev/null)" || true
    stray="$(awk -v self="$$" -v tmp="$TMP" \
      'index($0, tmp) && $1 != self && $2 != self {print $1}' <<<"$snap")" || true
    [[ -n "$stray" ]] || break
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      if ((i >= 50)); then kill -9 "$pid" 2>/dev/null || true; else kill "$pid" 2>/dev/null || true; fi
    done <<<"$stray"
    sleep 0.1
  done
  rm -rf "$TMP"
  # 회귀 게이트: teardown 이 센티널 자식을 놓치면 조용히 새는 게 아니라 스위트가
  # 실패해야 한다.
  if [[ -n "$escaped" ]]; then
    echo "FAIL: sentinel sleep children survived teardown: $escaped" >&2
    exit 1
  fi
}
trap cleanup EXIT
PROMPT="$TMP/prompt.md"
printf '%s\n' 'fixture prompt' >"$PROMPT"

# ROB-1252: cc-qwen38/cc-glm read the clinepass gate key from this file at
# spawn time (never from ~/.claude/); point it at a harmless fixture value.
export CLINEPASS_GATE_KEY_FILE="$TMP/clinepass-gate-key.txt"
printf 'fixture-gate-key\n' >"$CLINEPASS_GATE_KEY_FILE"

# ROB-1199: the suite must never reach a real arbiter state db or the real inbox.
# ARBITER_BIN points at nothing by default, so every pre-existing case keeps
# exercising the installation-transition path; the arbiter section below opts in.
export ARBITER_BIN="$TMP/absent-arbiter"
export XDG_DATA_HOME="$TMP/xdg"
# #951: claude-kind spawns seed folder trust into ${CLAUDE_CONFIG_DIR:-$HOME}/
# .claude.json — the operator's real config must never be touched by a fixture
# spawn, so suite HOME is a fixture and ambient CLAUDE_CONFIG_DIR is unset (it
# would relocate the store; the dedicated #951 cases set it explicitly).
export HOME="$TMP/home"
mkdir -p "$HOME"
unset CLAUDE_CONFIG_DIR
# #912: devin-kind spawns register the spawn cwd in devin's trusted-workspaces
# store ($XDG_DATA_HOME/devin/cli/trusted_workspaces.json) before any pane
# exists, and refuse closed when the store is missing or corrupt. Seed the
# fixture store with $ROOT so every spawn_base devin case below is a covered
# no-op; the dedicated #912 cases run against their own fixture XDG roots.
mkdir -p "$XDG_DATA_HOME/devin/cli"
python3 - "$XDG_DATA_HOME/devin/cli/trusted_workspaces.json" "$ROOT" <<'PY'
import json, sys
json.dump({"trusted_paths": [sys.argv[2]]}, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
export ARBITER_INBOX_ROOT="$TMP/inbox"
# Nor the operator's real spill-over config: under host load it moved fixture
# spawns onto a real remote host (or died with rc 2 on its cwd_map). Cases
# that exercise spill-over pass their own WRK_HOSTS_CONFIG.
export WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml"

# R20: `wrk done/escalate/joined` now notify panewire. The suite must never
# reach a real one, so every case runs against the silent fixture below; the
# R20 section opts into capture, failure and stalling through its environment.
PANEWIRE="$ROOT/tests/fixtures/panewire"
export PANEWIRE_BIN="$PANEWIRE"

# Document uploads are also opt-in below; the R21 section installs its own
# scripted handoffkeep. #768 made every spawn bind a task, so the spawn paths
# point at the deterministic fixture: pre-existing cases inherit one seeded
# suite task through HK_TASK_ID (the same env a spawned pane receives), while
# spawn_base mints a fresh --task per call so owner-mode claims run for real.
export HANDOFFKEEP_BIN="$ROOT/tests/fixtures/handoffkeep"
export HK_STATE="$TMP/hk-state.json"
export HK_TASK_ID=76801
"$HANDOFFKEEP_BIN" tasks add --id "$HK_TASK_ID" --title "suite-inherited-task" --lane fixture >/dev/null
# Pre-mint the owner-mode task pool: spawn_base only bumps the counter file,
# never calls the fixture at spawn time — some cases stub python3 (the fixture
# is python) to probe the awk TOML fallback, and minting must not die there.
python3 - "$HK_STATE" <<'PY'
import json, sys
path = sys.argv[1]
try:
    state = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    state = {"tasks": {}}
for i in range(768001, 768800):
    state["tasks"][str(i)] = {
        "id": i, "lane": "", "title": "spawn-base pool", "kind": "implement",
        "state": "backlog", "priority": 0, "refs": {}, "claimed_by": "",
        "created_by": "fixture", "created_at": "2026-01-01T00:00:00+00:00",
        "updated_at": "2026-01-01T00:00:00+00:00", "events": []}
json.dump(state, open(path, "w", encoding="utf-8"))
PY

run_fail() {
  if "$@" >/dev/null 2>&1; then
    echo "expected failure: $*" >&2
    exit 1
  fi
}

expect_exit() {
  local want="$1"; shift
  local rc=0
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne "$want" ]]; then
    echo "expected exit $want, got $rc: $*" >&2
    exit 1
  fi
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# mint_task — next id from the pre-minted pool. File-backed so it survives the
# command-substitution subshells most spawn callers use.
mint_task() {
  local id=$(( $(cat "$TMP/mint-seq" 2>/dev/null || echo 768000) + 1 ))
  printf '%s\n' "$id" >"$TMP/mint-seq"
  printf '%s\n' "$id"
}

event_count() {
  find "$1" -name "*$2.json" 2>/dev/null | wc -l | tr -d ' '
}

wait_until() {
  local limit="$1"; shift
  local deadline=$(( $(date +%s) + limit ))
  while (( $(date +%s) <= deadline )); do
    if "$@"; then return 0; fi
    sleep 0.2
  done
  return 1
}

event_count_is() {
  [[ "$(event_count "$1" "$2")" -eq "$3" ]]
}

sentinel_lost_reason() {
  python3 - "$1" <<'PY'
import glob, json, sys
for path in sorted(glob.glob(sys.argv[1] + "/*job.lost.json")):
    print(json.load(open(path)).get("reason", ""))
PY
}

# --t is required by wrk; supply one unless the case under test provides its own.
spawn_base() {
  local model="$1"; shift
  local extra=("$@")
  case " ${extra[*]-} " in *" --t "*) ;; *) extra+=(--t T1) ;; esac
  # #768: every spawn binds an hk task. Mint a fresh fixture task per spawn so
  # owner-mode claims stay claimable; a case that supplies --task/--parent-job
  # or unsets the task entirely (TEST_NO_TASK=1, e.g. usage-error probes)
  # overrides this.
  case " ${extra[*]-} " in
    *" --task "*|*" --parent-job "*) ;;
    *)
      if [[ -z "${TEST_NO_TASK:-}" ]]; then
        SPAWN_BASE_TASK="$(mint_task)"
        extra+=(--task "$SPAWN_BASE_TASK")
      fi ;;
  esac
  # Record the effective --task each call carries. spawn_base often runs
  # inside $(...), so a global is lost to the parent shell — a log file is
  # the subshell-safe channel (tail -1 after a call = that call's task).
  local resolved_task="" i
  for ((i = 0; i < ${#extra[@]}; i++)); do
    [[ "${extra[$i]}" == "--task" ]] && resolved_task="${extra[$((i + 1))]}"
  done
  [[ -n "$resolved_task" ]] && printf '%s\n' "$resolved_task" >>"$TMP/spawn-task.log"
  # A registered job leaves a detached sentinel behind, and that sentinel keeps
  # calling the fixture herdr — which appends every invocation to the shared
  # WRK_FIXTURE_LOG. At the default 30s interval one of those probes lands, about
  # once in three runs, between a case's `rm -f "$TMP/herdr.log"` and its
  # `[[ ! -e "$TMP/herdr.log" ]]`, and the suite dies there with no message.
  # Park the probes past the end of the run instead.
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_COMPLETION_INTERVAL_S="${WRK_COMPLETION_INTERVAL_S:-3600}" \
    WRK_FIXTURE_SCENARIO="${TEST_FIXTURE_SCENARIO:-spawn}" WRK_FIXTURE_LOG="$TMP/herdr.log" \
    WRK_FIXTURE_MARKER="${WRK_FIXTURE_MARKER:-}" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S="${WRK_REFRESH_TIMEOUT_S:-5}" \
    "$WRK" spawn \
    -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture "${extra[@]}"
}

# -- #912 devin trusted-workspaces helpers -----------------------------------
# wrk registers the resolved spawn cwd — and only it — in devin's trusted
# store ($XDG_DATA_HOME/devin/cli/trusted_workspaces.json) before any pane
# exists: append-only, inherited-coverage no-op, fail-closed on a missing or
# corrupt store. Every case uses a fixture XDG root under $TMP; the real user
# store is never touched. devin_spawn_at mirrors spawn_base's env but takes
# the XDG root and -c cwd as parameters.
devin_spawn_at() {
  local xdg="$1" dcwd="$2" label="$3" task="$4"; shift 4
  case "$xdg" in
    "$TMP"/*) ;;
    *) fail "devin_spawn_at requires a fixture XDG root under TMP: $xdg" ;;
  esac
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    XDG_DATA_HOME="$xdg" \
    ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO="${TEST_FIXTURE_SCENARIO:-devin-idle}" \
    WRK_FIXTURE_LOG="$TMP/herdr-$label.log" WRK_FIXTURE_MARKER="" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel-$label.log" \
    WRK_REFRESH_LOG="$TMP/refresh-$label.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh-$label.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_TEST_TRUST_DELAY_S="${WRK_TEST_TRUST_DELAY_S:-}" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$dcwd" -m devin-swe2 -p "$PROMPT" \
    -w w -l "$label" --t T1 --task "$task" "$@"
}

devin_trust_seed_store() {  # XDG_ROOT ENTRY...
  local xdg="$1"; shift
  mkdir -p "$xdg/devin/cli"
  python3 - "$xdg/devin/cli/trusted_workspaces.json" "$@" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"trusted_paths": list(sys.argv[2:])}, handle, indent=2)
PY
}

devin_trust_paths() {  # XDG_ROOT — entries one per line; fails if unparsable
  python3 - "$1/devin/cli/trusted_workspaces.json" <<'PY'
import json, sys
for entry in json.load(open(sys.argv[1], encoding="utf-8"))["trusted_paths"]:
    print(entry)
PY
}

devin_trust_mutant() {  # NAME OLD NEW — writes $TMP/mut-wrk-NAME, asserts applied
  python3 - "$WRK" "$TMP/mut-wrk-$1" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old, new = sys.argv[3], sys.argv[4]
assert src.count(old) == 1, "mutant anchor not unique: %r" % old
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY
  chmod +x "$TMP/mut-wrk-$1"
  grep -qF "$3" "$TMP/mut-wrk-$1" || fail "devin trust mutant $1 did not apply"
}

# -- #951 claude folder-trust helpers ----------------------------------------
# wrk records projects[<resolved cwd>].hasTrustDialogAccepted = true in
# ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json for PROFILE_KIND=claude before any
# pane exists — fail-open, atomic, other keys and projects preserved. Every
# case uses a fixture HOME under $TMP; the real user config is never touched.
# claude_spawn_at mirrors devin_spawn_at but parametrizes HOME (and unsets
# CLAUDE_CONFIG_DIR so the default path is exercised); MODEL defaults to
# sonnet so non-claude kinds can be driven through the same helper.
claude_spawn_at() {
  local home="$1" ccwd="$2" label="$3" task="$4" model="${5:-sonnet}"
  case "$home" in
    "$TMP"/*) ;;
    *) fail "claude_spawn_at requires a fixture HOME under TMP: $home" ;;
  esac
  shift 4
  if (($#)); then shift; fi  # drop the optional MODEL; rest are extra wrk args
  env -u CLAUDE_CONFIG_DIR HOME="$home" HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/herdr-$label.log" WRK_FIXTURE_MARKER="" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel-$label.log" \
    WRK_REFRESH_LOG="$TMP/refresh-$label.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh-$label.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_TEST_TRUST_DELAY_S="${WRK_TEST_TRUST_DELAY_S:-}" \
    WRK_TEST_TRUST_LOCK_TIMEOUT_S="${WRK_TEST_TRUST_LOCK_TIMEOUT_S:-}" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ccwd" -m "$model" -p "$PROMPT" \
    -w w -l "$label" --t T1 --task "$task" "$@"
}

claude_trust_entry() {  # STORE_PATH ABS_CWD — prints the projects entry (JSON), "absent" if none
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    print("absent")
    raise SystemExit(0)
entry = data.get("projects", {}).get(sys.argv[2])
print("absent" if entry is None else json.dumps(entry, sort_keys=True, separators=(",", ":")))
PY
}

claude_trust_mutant() {  # NAME OLD NEW — same generic source replace as devin_trust_mutant
  devin_trust_mutant "$@"
}

hub_quota_run_case() {
  local name="$1" hub_rc="$2" gate_mode="$3" config="$4"
  HUB_QUOTA_OUT="$TMP/hub-quota-$name.out"
  HUB_QUOTA_ERR="$TMP/hub-quota-$name.err"
  HUB_QUOTA_PANEWIRE_LOG="$TMP/hub-quota-$name-panewire.log"
  HUB_QUOTA_HERDR_LOG="$TMP/hub-quota-$name-herdr.log"
  HUB_QUOTA_SPILLOVER_LOG="$TMP/hub-quota-$name-spillover.log"
  : >"$HUB_QUOTA_PANEWIRE_LOG"
  : >"$HUB_QUOTA_HERDR_LOG"
  : >"$HUB_QUOTA_SPILLOVER_LOG"
  set +e
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_BIN="$ARBITER" XDG_DATA_HOME="$TMP/hub-quota-xdg-$name" \
    ARBITER_INBOX_ROOT="$TMP/hub-quota-inbox-$name" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$HUB_QUOTA_HERDR_LOG" WRK_SCOPEFUEL_LOG="$TMP/hub-quota-scopefuel.log" \
    WRK_REFRESH_LOG="$TMP/hub-quota-refresh.log" WRK_REFRESH_PID_LOG="$TMP/hub-quota-refresh.pids" \
    WRK_REFRESH_TIMEOUT_S=5 WRK_HOSTS_CONFIG="$config" \
    WRK_SPILLOVER_LOG="$HUB_QUOTA_SPILLOVER_LOG" \
    WRK_PANEWIRE_LOG="$HUB_QUOTA_PANEWIRE_LOG" WRK_PANEWIRE_RC="$hub_rc" \
    WRK_GATE_MODE="$gate_mode" \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 --host local \
    >"$HUB_QUOTA_OUT" 2>"$HUB_QUOTA_ERR"
  HUB_QUOTA_RC=$?
  set -e
}

hub_quota_expect_rc() {
  local name="$1" want="$2"
  [[ "$HUB_QUOTA_RC" -eq "$want" ]] ||
    fail "hub quota combination $name expected exit $want, got $HUB_QUOTA_RC"
}

hub_quota_expect_spawn() {
  local name="$1" want="$2"
  if [[ "$want" -eq 1 ]]; then
    [[ -s "$HUB_QUOTA_HERDR_LOG" ]] ||
      fail "hub quota combination $name expected spawn"
  elif [[ -s "$HUB_QUOTA_HERDR_LOG" ]]; then
    fail "hub quota combination $name unexpectedly spawned"
  fi
}

run_t1090_remote_err_tests() {
  # -- #1090: a failed remote spawn must say why -------------------------------
  # The remote legs used to swallow the remote's own words: the probe and the
  # prepare check ran under 2>/dev/null, a refused candidate was skipped without
  # a line, and the router's last message carried an initialized rc=1 naming no
  # step. The contract pinned here: remote stderr and non-OK remote stdout land
  # on the local stderr, and the final line names the failed step and its rc.
  T1090_LOAD="$TMP/t1090-loadavg"
  printf '0.20 0.10 0.10 1/1 1\n' >"$T1090_LOAD"
  T1090_HOSTS="$TMP/t1090-hosts.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$ROOT\"=\"/remote/agent-skills\"}" 'capacity = 3' >"$T1090_HOSTS"
  # A suffix-kind mapping actually opens the prepare leg (exact mappings return
  # before any remote check). The .wt sibling directory stands in for a derived
  # worktree path so the sh -s leg is exercised end to end.
  T1090_SUFFIX_ROOT="$TMP/t1090-lrepo"
  mkdir -p "$T1090_SUFFIX_ROOT" "${T1090_SUFFIX_ROOT}.wt"
  T1090_HOSTS_SUFFIX="$TMP/t1090-hosts-suffix.toml"
  printf '%s\n' '[local]' 'max_load_ratio = 0.5' 'max_active = 4' '' \
    '[hosts.desktop]' 'ssh = "desktop"' 'herdr_session = "worker"' 'workspace = "workers"' \
    "cwd_map = {\"$T1090_SUFFIX_ROOT\"=\"/remote/lrepo\"}" 'capacity = 3' >"$T1090_HOSTS_SUFFIX"
  # The router refuses remote placement while the arbiter lookup is unreadable;
  # a seeded claim makes the block-private inbox a real database for preflight
  # to read — it stays out of the shared $TMP/inbox other sections assert on.
  T1090_INBOX="$TMP/t1090-inbox" T1090_XDG="$TMP/t1090-xdg"
  env ARBITER_INBOX_ROOT="$T1090_INBOX" XDG_DATA_HOME="$T1090_XDG" \
    "$ARBITER" claim --job t1090-seed --agent-label t1090-seed --lane t1090 --t T1 >/dev/null

  t1090_spawn() {  # env knobs per call: T1090_{SSH,SCP}_SCENARIO, T1090_{HOSTS_OVERRIDE,CWD,WRK}
    env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
      ARBITER_BIN="$ARBITER" ARBITER_INBOX_ROOT="$T1090_INBOX" XDG_DATA_HOME="$T1090_XDG" \
      WRK_HOSTS_CONFIG="${T1090_HOSTS_OVERRIDE:-$T1090_HOSTS}" WRK_PROC_LOADAVG="$T1090_LOAD" \
      WRK_TEST_NCPU=4 WRK_TEST_THROTTLED=0 \
      WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/t1090-herdr.log" \
      WRK_SPILLOVER_LOG="$TMP/t1090-spillover.log" \
      PANEWIRE_BIN="$PANEWIRE" WRK_WAKE_LOG="$TMP/t1090-wake.log" \
      WRK_SSH_BIN="$ROOT/tests/fixtures/spillover-ssh" \
      WRK_SCP_BIN="${T1090_SCP:-$ROOT/tests/fixtures/spillover-scp}" \
      WRK_SSH_LOG="$TMP/t1090-ssh.log" WRK_SCP_LOG="$TMP/t1090-scp.log" \
      WRK_SSH_SCENARIO="${T1090_SSH_SCENARIO:-ok}" \
      WRK_SCP_SCENARIO="${T1090_SCP_SCENARIO:-ok}" \
      "${T1090_WRK:-$WRK}" spawn -c "${T1090_CWD:-$ROOT}" -m codex-terra -p "$PROMPT" \
      -w w -l fixture --t T1 --job "t1090-$RANDOM-$RANDOM" --host desktop
  }

  # AC1: the remote wrk dies on stderr — the die line reaches the local stderr
  # and the final line names the remote wrk step and its rc.
  set +e
  ( T1090_SSH_SCENARIO=remote-die-stderr t1090_spawn ) >"$TMP/t1090-ac1.out" 2>"$TMP/t1090-ac1.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC1: remote rc=1 must propagate, got $t1090_rc"
  grep -qF "hk task 1037 is already bound to job 'other-job'" "$TMP/t1090-ac1.err" ||
    fail "AC1: remote stderr die line never reached local stderr: $(cat "$TMP/t1090-ac1.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac1.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"remote wrk"* && "$t1090_last" == *"no local fallback"* ]] ||
    fail "AC1: final line must name the remote wrk step and rc=1, got: $t1090_last"
  [[ ! -s "$TMP/t1090-ac1.out" ]] || fail "AC1: a failed spawn must not write to stdout: $(cat "$TMP/t1090-ac1.out")"
  echo "PASS t1090 AC1 remote-stderr-relayed"

  # AC2: the remote wrk prints its refusal on stdout — same contract, and the
  # line must move to stderr rather than masquerade on the OK stream.
  set +e
  ( T1090_SSH_SCENARIO=remote-die-stdout t1090_spawn ) >"$TMP/t1090-ac2.out" 2>"$TMP/t1090-ac2.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC2: remote rc=1 must propagate, got $t1090_rc"
  grep -qF "hk task 1037 is already bound to job 'other-job'" "$TMP/t1090-ac2.err" ||
    fail "AC2: remote stdout refusal never reached local stderr: $(cat "$TMP/t1090-ac2.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac2.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"remote wrk"* ]] ||
    fail "AC2: final line must name the remote wrk step and rc=1, got: $t1090_last"
  ! grep -qF 'already bound' "$TMP/t1090-ac2.out" ||
    fail "AC2: remote refusal must not stay on stdout: $(cat "$TMP/t1090-ac2.out")"
  echo "PASS t1090 AC2 remote-stdout-relayed"

  # AC3: prepare, mktemp and scp failures each name their step on the final
  # line, and each leg's stderr reaches the local stderr.
  set +e
  ( T1090_HOSTS_OVERRIDE="$T1090_HOSTS_SUFFIX" T1090_CWD="${T1090_SUFFIX_ROOT}.wt" \
    T1090_SSH_SCENARIO=prepare-fails t1090_spawn ) >"$TMP/t1090-ac3a.out" 2>"$TMP/t1090-ac3a.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 255 ]] || fail "AC3 prepare: ssh rc must propagate, got $t1090_rc"
  grep -qF 'Connection refused' "$TMP/t1090-ac3a.err" ||
    fail "AC3 prepare: remote check stderr dropped: $(cat "$TMP/t1090-ac3a.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3a.err")"
  [[ "$t1090_last" == *"rc=255"* && "$t1090_last" == *"prepare"* ]] ||
    fail "AC3 prepare: final line must name the prepare step and rc, got: $t1090_last"

  set +e
  ( T1090_SSH_SCENARIO=mktemp-fails t1090_spawn ) >"$TMP/t1090-ac3b.out" 2>"$TMP/t1090-ac3b.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC3 mktemp: remote rc must propagate, got $t1090_rc"
  grep -qF 'No space left on device' "$TMP/t1090-ac3b.err" ||
    fail "AC3 mktemp: remote mktemp stderr dropped: $(cat "$TMP/t1090-ac3b.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3b.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"mktemp"* ]] ||
    fail "AC3 mktemp: final line must name the mktemp step and rc, got: $t1090_last"

  set +e
  ( T1090_SCP_SCENARIO=fail t1090_spawn ) >"$TMP/t1090-ac3c.out" 2>"$TMP/t1090-ac3c.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC3 scp: scp rc must propagate, got $t1090_rc"
  grep -qF 'scp: dest open' "$TMP/t1090-ac3c.err" ||
    fail "AC3 scp: scp stderr missing: $(cat "$TMP/t1090-ac3c.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3c.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"scp"* ]] ||
    fail "AC3 scp: final line must name the scp step and rc, got: $t1090_last"

  # A refused probe is the failure that produced the incident's bare rc=1 line:
  # the probe reason and the remote's stderr must be named, the step is 'probe'.
  set +e
  ( T1090_SSH_SCENARIO=probe-herdr-missing t1090_spawn ) >"$TMP/t1090-ac3d.out" 2>"$TMP/t1090-ac3d.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 1 ]] || fail "AC3 probe: expected rc=1, got $t1090_rc"
  grep -qF 'herdr: command not found' "$TMP/t1090-ac3d.err" ||
    fail "AC3 probe: remote probe stderr dropped: $(cat "$TMP/t1090-ac3d.err")"
  grep -q 'remote-full' "$TMP/t1090-ac3d.err" ||
    fail "AC3 probe: refusal reason missing: $(cat "$TMP/t1090-ac3d.err")"
  t1090_last="$(tail -n 1 "$TMP/t1090-ac3d.err")"
  [[ "$t1090_last" == *"rc=1"* && "$t1090_last" == *"probe"* ]] ||
    fail "AC3 probe: final line must name the probe step and rc, got: $t1090_last"
  echo "PASS t1090 AC3 failed-steps-named"

  # AC4: the success path is byte-identical to main — the annotated OK line on
  # stdout, nothing on stderr, rc 0.
  set +e
  ( t1090_spawn ) >"$TMP/t1090-ac4.out" 2>"$TMP/t1090-ac4.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] || fail "AC4: success rc must stay 0, got $t1090_rc"
  printf '%s\n' 'OK pane=desktop:p7 host=desktop model=codex-terra label=fixture status=working landed=yes' >"$TMP/t1090-ac4.want"
  cmp -s "$TMP/t1090-ac4.want" "$TMP/t1090-ac4.out" ||
    fail "AC4: success stdout differs from the pinned OK line: $(cat "$TMP/t1090-ac4.out")"
  [[ ! -s "$TMP/t1090-ac4.err" ]] ||
    fail "AC4: success stderr must stay empty: $(cat "$TMP/t1090-ac4.err")"
  echo "PASS t1090 AC4 success-byte-identical"

  # AC5 invariants as assertion-RED mutants.
  # M1 'a remote failure is never silent': dropping the stderr relay and the
  # failure-mode stdout routing must turn AC1 red.
  T1090_M1="$TMP/t1090-wrk-no-relay"
  # shellcheck disable=SC2016 # the sed patterns are bin/wrk source text, not expansions
  sed -e 's/spillover_relay_remote_err "\$remote_err"/:/' \
      -e 's/spillover_emit_host "\$host" "\$out" "\$rc"/spillover_emit_host "$host" "$out"/' \
      "$WRK" >"$T1090_M1"
  chmod +x "$T1090_M1"
  # shellcheck disable=SC2016 # the grep pattern is bin/wrk source text
  grep -qF 'spillover_emit_host "$host" "$out"' "$T1090_M1" || fail 'M1 mutant did not apply'
  set +e
  ( T1090_WRK="$T1090_M1" T1090_SSH_SCENARIO=remote-die-stderr t1090_spawn ) >"$TMP/t1090-m1.out" 2>"$TMP/t1090-m1.err"
  set -e
  if grep -qF "hk task 1037 is already bound to job 'other-job'" "$TMP/t1090-m1.err"; then
    fail "M1: dropping the remote relay must turn AC1 red, but the die line survived"
  fi
  echo "PASS t1090 M1: silent-failure mutant goes RED (AC1 assertion: remote die line absent from stderr)"

  # M2 'the success path is unchanged': also forwarding remote stdout to stderr
  # on a successful leg must turn AC4 red.
  T1090_M2="$TMP/t1090-wrk-stdout-forward"
  # shellcheck disable=SC2016 # the sed pattern is bin/wrk source text, not an expansion site
  sed 's/spillover_emit_host "\$host" "\$out" "\$rc"/cat "\$out" >\&2; spillover_emit_host "$host" "$out" "$rc"/' \
      "$WRK" >"$T1090_M2"
  chmod +x "$T1090_M2"
  # shellcheck disable=SC2016 # the grep pattern is mutant source text
  grep -qF 'cat "$out" >&2' "$T1090_M2" || fail 'M2 mutant did not apply'
  set +e
  ( T1090_WRK="$T1090_M2" t1090_spawn ) >"$TMP/t1090-m2.out" 2>"$TMP/t1090-m2.err"
  t1090_rc=$?
  set -e
  [[ "$t1090_rc" -eq 0 ]] || fail "M2: mutant spawn itself failed (rc=$t1090_rc)"
  if cmp -s "$TMP/t1090-ac4.want" "$TMP/t1090-m2.out" && [[ ! -s "$TMP/t1090-m2.err" ]]; then
    fail "M2: forwarding stdout on success must turn AC4 red, but output stayed identical"
  fi
  echo "PASS t1090 M2: stdout-on-success mutant goes RED (AC4 assertion: stderr no longer empty)"
}

# Slice gate: WRK_TEST_ONLY_REMOTE_ERR=1 runs only this section after the
# shared fixture setup — the remote legs are fakes, so no real ssh/spawn runs.
if [[ "${WRK_TEST_ONLY_REMOTE_ERR:-0}" -eq 1 ]]; then
  run_t1090_remote_err_tests
  exit 0
fi
run_t1090_remote_err_tests

run_hub_quota_gate_tests() {
  local configured="$TMP/hub-quota-hosts.toml"
  local unconfigured="$TMP/hub-quota-no-hub.toml"
  local token_file="$TMP/hub-quota-operator.env"
  local cf_file="$TMP/hub-quota-cf.env"
  local token_value="fixture-quota-token-must-not-leak"
  printf 'HUB_TOKEN=%s\n' "$token_value" >"$token_file"
  printf 'CF_ACCESS_CLIENT_ID=fixture\nCF_ACCESS_CLIENT_SECRET=fixture\n' >"$cf_file"
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nhub_cf_env = "%s"\n' \
    "$token_file" "$cf_file" >"$configured"
  printf '[local]\nmax_load_ratio = 1.0\n' >"$unconfigured"

  # W1 isolates the original scopefuel exit contract with no [hub] section.
  # These assertions intentionally precede the policy-combination table so a
  # broad relaxation of `3|4) exit "$rc"` fails at the legacy boundary.
  hub_quota_run_case local-contract-3 0 3 "$unconfigured"
  hub_quota_expect_rc local-contract-3 3
  hub_quota_expect_spawn local-contract-3 0
  grep -q 'gate blocked profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "W1 scopefuel exit 3 stderr was not preserved"
  echo "PASS hub-quota-local-contract exit-3=deny"

  hub_quota_run_case local-contract-4 0 4 "$unconfigured"
  hub_quota_expect_rc local-contract-4 4
  hub_quota_expect_spawn local-contract-4 0
  grep -q 'gate measurement unavailable profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "W1 scopefuel exit 4 stderr was not preserved"
  echo "PASS hub-quota-local-contract exit-4=unknown"

  # The scopefuel success payload remains the exact two-line prefix consumed by
  # arbiter. The hub call receives only the pool emitted by scopefuel.
  hub_quota_run_case allow-local-0 0 ok "$configured"
  hub_quota_expect_rc allow/local-0 0
  hub_quota_expect_spawn allow/local-0 1
  [[ "$(sed -n '1p' "$HUB_QUOTA_OUT")" == 'profile=codex-terra-max pool=codex used_pct=12.5 class=preserve' ]] ||
    fail "scopefuel gate stdout line 1 was not reprinted verbatim"
  [[ "$(sed -n '2p' "$HUB_QUOTA_OUT")" == 'gate allowed profile=codex-terra-max' ]] ||
    fail "scopefuel gate stdout line 2 was not reprinted verbatim"
  python3 - "$HUB_QUOTA_PANEWIRE_LOG" "$ROOT" "$token_file" "$cf_file" <<'PY' ||
import sys
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
want = [
    "place", "--class", "worker", "--cwd", sys.argv[2], "--pool", "codex",
    "--hub-url", "https://hub.invalid", "--hub-token-env", sys.argv[3],
    "--hub-cf-env", sys.argv[4], "--",
]
if got != want:
    raise SystemExit(f"hub quota argv mismatch: got={got!r} want={want!r}")
PY
    fail "hub quota allow invocation did not preserve the panewire contract"
  echo "PASS hub-quota-combination allow/0=allow"

  # Local denial/unknown terminates before hub policy can override it. The fake
  # hub is configured to allow, and non-invocation is part of the assertion.
  hub_quota_run_case allow-local-3 0 3 "$configured"
  hub_quota_expect_rc allow/local-3 3
  hub_quota_expect_spawn allow/local-3 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub allow was consulted after local exit 3"
  grep -q 'gate blocked profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "scopefuel exit 3 stderr was not preserved"
  echo "PASS hub-quota-combination allow/3=deny"

  hub_quota_run_case allow-local-4 0 4 "$configured"
  hub_quota_expect_rc allow/local-4 4
  hub_quota_expect_spawn allow/local-4 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub allow was consulted after local exit 4"
  grep -q 'gate measurement unavailable profile=codex-terra-max' "$HUB_QUOTA_ERR" ||
    fail "scopefuel exit 4 stderr was not preserved"
  echo "PASS hub-quota-combination allow/4=unknown"

  hub_quota_run_case deny-local-0 5 ok "$configured"
  hub_quota_expect_rc deny/local-0 5
  hub_quota_expect_spawn deny/local-0 0
  grep -q 'hub quota policy denied' "$HUB_QUOTA_ERR" ||
    fail "hub exit 5 was not classified as deny"
  echo "PASS hub-quota-combination deny/0=deny"

  hub_quota_run_case unavailable-local-0 4 ok "$configured"
  hub_quota_expect_rc unavailable/local-0 0
  hub_quota_expect_spawn unavailable/local-0 1
  grep -q 'hub quota policy unavailable; using local scopefuel result' "$HUB_QUOTA_ERR" ||
    fail "hub exit 4 did not take the approved fallback"
  echo "PASS hub-quota-combination unavailable/0=allow"

  hub_quota_run_case unavailable-local-3 4 3 "$configured"
  hub_quota_expect_rc unavailable/local-3 3
  hub_quota_expect_spawn unavailable/local-3 0
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "unavailable hub was consulted after local exit 3"
  echo "PASS hub-quota-combination unavailable/3=deny"

  hub_quota_run_case authentication-local-0 6 ok "$configured"
  hub_quota_expect_rc authentication_error/local-0 6
  hub_quota_expect_spawn authentication_error/local-0 0
  grep -q 'hub quota policy authentication failed' "$HUB_QUOTA_ERR" ||
    fail "hub exit 6 was not classified as authentication error"
  echo "PASS hub-quota-combination authentication_error/0=authentication_error"

  hub_quota_run_case malformed-local-0 70 ok "$configured"
  hub_quota_expect_rc fail_closed/local-0 70
  hub_quota_expect_spawn fail_closed/local-0 0
  grep -q 'hub quota policy response rejected' "$HUB_QUOTA_ERR" ||
    fail "hub exit 70 was not classified fail-closed"
  echo "PASS hub-quota-combination fail_closed/0=fail_closed"

  # Usage is also fail-closed. Of panewire's nonzero outcomes, only 4 spawns.
  hub_quota_run_case usage-local-0 2 ok "$configured"
  hub_quota_expect_rc usage/local-0 2
  hub_quota_expect_spawn usage/local-0 0
  grep -q 'hub quota policy invocation rejected' "$HUB_QUOTA_ERR" ||
    fail "hub exit 2 did not fail closed"
  echo "PASS hub-quota-only-exit-4-falls-back"

  # A readable hosts.toml without [hub] is the original local-only path.
  hub_quota_run_case unconfigured-local-0 70 ok "$unconfigured"
  hub_quota_expect_rc unconfigured/local-0 0
  hub_quota_expect_spawn unconfigured/local-0 1
  [[ ! -s "$HUB_QUOTA_PANEWIRE_LOG" ]] ||
    fail "hub-unconfigured local-only path invoked panewire"
  [[ "$(sed -n '1p' "$HUB_QUOTA_OUT")" == 'profile=codex-terra-max pool=codex used_pct=12.5 class=preserve' ]] ||
    fail "hub-unconfigured path changed local gate stdout"
  echo "PASS hub-quota-unconfigured-preserves-local-only"

  # The credential files are passed by path only. Neither their contents nor
  # panewire output can enter wrk's stdout, stderr, or spill-over audit log.
  for output in "$TMP"/hub-quota-*.out "$TMP"/hub-quota-*.err "$TMP"/hub-quota-*-spillover.log; do
    if grep -Fq "$token_value" "$output"; then
      fail "hub token leaked into ${output##*/}"
    fi
  done
  echo "PASS hub-quota-token-redaction"
}

if [[ "${WRK_TEST_ONLY_HUB_QUOTA:-0}" -eq 1 ]]; then
  run_hub_quota_gate_tests
  exit 0
fi
run_hub_quota_gate_tests

# ---------------------------------------------------------------------------
# #965: a worker spawned under a hub-mapped herdr session registers a lane
# ---------------------------------------------------------------------------
# A host can run a second panewire daemon serving a non-fleet herdr session;
# hosts.toml's [hub] session_machine_ids maps the session to that daemon's hub
# machine id. A local --role worker spawn under a mapped session then runs
# `panewire lanes add` exactly once — after the pane is provably up, before the
# job.spawned receipt so the lane lands in the same job meta — and
# `wrk reap --apply` removes exactly that lane. Registration is warn-only at
# every step: an unmapped session, a missing --owner and a panewire refusal all
# spawn unregistered, and builder spawns never reach the call at all.
LANES_CFG="$TMP/lanes-hosts.toml"
LANES_TOKEN_FILE="$TMP/lanes-token.env"
LANES_CF_FILE="$TMP/lanes-cf.env"
LANES_TOKEN_VALUE="fixture-lanes-token-must-not-leak"
LANES_CF_VALUE="fixture-lanes-cf-must-not-leak"
printf 'HUB_TOKEN=%s\n' "$LANES_TOKEN_VALUE" >"$LANES_TOKEN_FILE"
printf 'CF_ACCESS_CLIENT_ID=fixture\nCF_ACCESS_CLIENT_SECRET=%s\n' "$LANES_CF_VALUE" >"$LANES_CF_FILE"
printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nhub_cf_env = "%s"\nsession_machine_ids = { "default" = "mac-work-default" }\n' \
  "$LANES_TOKEN_FILE" "$LANES_CF_FILE" >"$LANES_CFG"
# AC7's tripwire: the paths are passed to panewire, never opened — chmod 000
# turns a silent read of either file into a loud failure instead.
chmod 000 "$LANES_TOKEN_FILE" "$LANES_CF_FILE"
# A config with [hub] but no session_machine_ids key: the installation has not
# opted in, so the spawn stays silent — no warning, no call.
LANES_CFG_NOMAP="$TMP/lanes-nomap-hosts.toml"
printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nhub_cf_env = "%s"\n' \
  "$LANES_TOKEN_FILE" "$LANES_CF_FILE" >"$LANES_CFG_NOMAP"

lanes_spawn() {
  # NAME [spawn args...] — a forced-local spawn against the #965 hosts.toml.
  # stdout/stderr, both panewire logs and the inbox land in per-case paths;
  # the exit code lands in LANES_RC. LANES_CFG_OVERRIDE swaps the hosts.toml,
  # LANES_MODEL the profile.
  local name="$1"; shift
  LANES_OUT="$TMP/lanes-$name.out" LANES_ERR="$TMP/lanes-$name.err"
  LANES_CALLS="$TMP/lanes-$name-calls.log" LANES_HERDR_LOG="$TMP/lanes-$name-herdr.log"
  LANES_PANEWIRE_LOG="$TMP/lanes-$name-panewire.log"
  LANES_INBOX="$TMP/lanes-inbox-$name"
  set +e
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" PANEWIRE_BIN="$PANEWIRE" \
    ARBITER_BIN="${LANES_ARBITER_BIN:-$ARBITER}" ARBITER_INBOX_ROOT="$LANES_INBOX" \
    XDG_DATA_HOME="$TMP/lanes-xdg-$name" WRK_NO_SLEEP=1 \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$LANES_HERDR_LOG" \
    WRK_SCOPEFUEL_LOG="$TMP/lanes-scopefuel-$name.log" \
    WRK_REFRESH_LOG="$TMP/lanes-refresh-$name.log" \
    WRK_REFRESH_PID_LOG="$TMP/lanes-refresh-$name.pids" WRK_REFRESH_TIMEOUT_S=5 \
    WRK_HOSTS_CONFIG="${LANES_CFG_OVERRIDE:-$LANES_CFG}" \
    WRK_PANEWIRE_LOG="$LANES_PANEWIRE_LOG" \
    WRK_PANEWIRE_LANES_LOG="$LANES_CALLS" \
    "${WRK_UNDER_TEST:-$WRK}" spawn -c "$ROOT" -m "${LANES_MODEL:-codex-terra}" \
    -p "$PROMPT" -w w -l "$name" --t T1 --job "$name" --task "$(mint_task)" \
    --host local "$@" >"$LANES_OUT" 2>"$LANES_ERR"
  LANES_RC=$?
  set -e
}

# Zero lanes traffic means no dedicated argv block AND no `lanes` subcommand
# reaching the shared panewire log (place/prompt calls are unrelated).
lanes_assert_no_lanes_call() {
  local name="$1"
  [[ ! -s "$TMP/lanes-$name-calls.log" ]] ||
    fail "#965 $name: expected zero lanes calls, got: $(cat "$TMP/lanes-$name-calls.log")"
  if [[ -f "$TMP/lanes-$name-panewire.log" ]] && grep -q '^lanes$' "$TMP/lanes-$name-panewire.log"; then
    fail "#965 $name: a lanes subcommand reached panewire"
  fi
}

lanes_spawned_payload() {
  # NAME — print the single job.spawned receipt payload.
  python3 - "$TMP/lanes-inbox-$1/$1/events" <<'PY'
import glob, json, sys
paths = sorted(glob.glob(sys.argv[1] + "/*job.spawned.json"))
assert len(paths) == 1, "exactly one job.spawned receipt expected: %r" % paths
print(json.dumps(json.load(open(paths[0]))["payload"], sort_keys=True))
PY
}

lanes_reap_run() {
  # NAME [reap args...] — wrk reap against LANES_REAP_INBOX with the #965
  # hosts.toml; lanes rm argv lands in $TMP/lanes-rm-$name.log.
  local name="$1"; shift
  LANES_REAP_OUT="$TMP/lanes-reap-$name.out" LANES_REAP_ERR="$TMP/lanes-reap-$name.err"
  LANES_RM_LOG="$TMP/lanes-rm-$name.log"
  set +e
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" \
    WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$LANES_REAP_HERDR_LOG" \
    WRK_HOSTS_CONFIG="$LANES_CFG" \
    WRK_PANEWIRE_LANES_LOG="$LANES_RM_LOG" \
    "${WRK_UNDER_TEST:-$WRK}" reap "$@" >"$LANES_REAP_OUT" 2>"$LANES_REAP_ERR"
  LANES_REAP_RC=$?
  set -e
}

lanes_reap_job() {
  # JOB PANE TAB LANE HUB_LANE [LABEL [MACHINE]] — claim + job.spawned
  # (+hub_lane/hub_lane_machine when nonempty) + job.completed, all backdated
  # past the default grace. LABEL defaults to JOB (#994 needs lane != job !=
  # label so a remove-by-job-id regression cannot pass silently).
  local job="$1" pane="$2" tab="$3" lane="$4" hub_lane="$5" label="${6:-$1}" machine="${7:-mac-work-default}"
  local spawned="{\"owner_lane\":\"$lane\",\"label\":\"$label\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}"
  if [[ -n "$hub_lane" ]]; then
    spawned="{\"owner_lane\":\"$lane\",\"label\":\"$label\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\",\"hub_lane\":\"$hub_lane\",\"hub_lane_machine\":\"$machine\"}"
  fi
  export ARBITER_TEST_NOW="$LANES_REAP_NOW"
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "$spawned" >/dev/null
  env ARBITER_INBOX_ROOT="$LANES_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}

run_lanes_tests() {
  # AC1 — mapped session + --owner: exactly one `lanes add` carrying the
  # configured machine, the spawned pane, the owner lane as parent and every
  # configured credential path. The OK line gains lane=LABEL@MACHINE and the
  # job meta records both fields.
  HERDR_SESSION=default lanes_spawn lane-ac1 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC1: mapped worker spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
want = ["add", "lane-ac1", "--machine", "mac-work-default", "--pane", "w:p1",
        "--parent", "work-kairos", "--hub-url", "https://hub.invalid",
        "--hub-token-env", token_file, "--hub-cf-env", cf_file, "--"]
assert got == want, "lanes add argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#965 AC1: lanes add must run exactly once with machine/pane/parent/credentials"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" ||
    fail "#965 AC1: the OK line is missing: $(cat "$LANES_OUT")"
  grep -q ' lane=lane-ac1@mac-work-default$' "$LANES_OUT" ||
    fail "#965 AC1: the OK line must end with lane=lane-ac1@mac-work-default: $(cat "$LANES_OUT")"
  lanes_spawned_payload lane-ac1 | python3 -c '
import json, sys
payload = json.loads(sys.stdin.read())
assert payload.get("hub_lane") == "lane-ac1", payload
assert payload.get("hub_lane_machine") == "mac-work-default", payload' ||
    fail "#965 AC1: job.spawned meta must carry hub_lane/hub_lane_machine"
  echo "PASS 965-lanes AC1: mapped worker spawn registers the lane"

  # Session resolution: WRK_SENTINEL_HERDR_SESSION wins over HERDR_SESSION;
  # with neither set the herdr default session is what gets mapped.
  WRK_SENTINEL_HERDR_SESSION=default HERDR_SESSION=worker \
    lanes_spawn lane-prec --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#965: sentinel-session override spawn failed"
  python3 - "$LANES_CALLS" <<'PY' ||
import sys
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert got[:2] == ["add", "lane-prec"], "sentinel session must win: %r" % got
assert got[2:4] == ["--machine", "mac-work-default"], got
PY
    fail "#965: WRK_SENTINEL_HERDR_SESSION must win over HERDR_SESSION"
  HERDR_SESSION='' WRK_SENTINEL_HERDR_SESSION='' lanes_spawn lane-def --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#965: default-session spawn failed"
  python3 - "$LANES_CALLS" <<'PY' ||
import sys
got = open(sys.argv[1], encoding="utf-8").read().splitlines()
assert got[:4] == ["add", "lane-def", "--machine", "mac-work-default"], \
    "an unset session must resolve to the herdr default: %r" % got
PY
    fail "#965: an unset herdr session must resolve to the default session"
  echo "PASS 965-lanes session precedence (sentinel override, default fallback)"

  # AC2 — mapped config but an unmapped session: zero lanes calls, exactly one
  # warning naming the session, and the OK line carries nothing appended.
  HERDR_SESSION=worker lanes_spawn lane-ac2 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC2: an unmapped-session spawn still succeeds (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-ac2
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#965 AC2: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -q "herdr session 'worker'" "$LANES_ERR" ||
    fail "#965 AC2: the warning must name the session: $(cat "$LANES_ERR")"
  grep -qxF 'OK pane=w:p1 host=local model=codex-terra label=lane-ac2 status=working landed=yes job=lane-ac2 quota_record=codex/quota_pool' "$LANES_OUT" ||
    fail "#965 AC2: the OK line changed beyond 'nothing appended': $(cat "$LANES_OUT")"
  # And a config without the key at all stays silent (opt-in absent).
  LANES_CFG_OVERRIDE="$LANES_CFG_NOMAP" HERDR_SESSION=default lanes_spawn lane-ac2b --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#965 AC2: unconfigured-map spawn failed"
  lanes_assert_no_lanes_call lane-ac2b
  ! grep -q 'hub lane' "$LANES_ERR" ||
    fail "#965 AC2: no session_machine_ids key must stay silent: $(cat "$LANES_ERR")"
  echo "PASS 965-lanes AC2: unmapped session warns once and spawns clean"

  # AC3 — a builder spawn never touches lanes. Builder lanes stay the
  # director's; the same mapped session and daemon are irrelevant here.
  LANES_MODEL=builder-sol HERDR_SESSION=default \
    lanes_spawn lane-ac3 --role builder --lane b965-builder --parent director-x
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC3: builder spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call lane-ac3
  ! grep -q 'hub lane' "$LANES_ERR" ||
    fail "#965 AC3: a builder spawn must not even warn about hub lanes: $(cat "$LANES_ERR")"
  echo "PASS 965-lanes AC3: builder spawns never register"

  # AC4 — mapped session, missing --owner: zero calls, one warning, rc
  # unchanged (the spawn is still a success — a missing lane is pre-#965
  # behaviour, not a new failure).
  HERDR_SESSION=default lanes_spawn lane-ac4
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC4: a missing --owner must not fail the spawn (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-ac4
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#965 AC4: exactly one warning expected: $(cat "$LANES_ERR")"
  grep -q -- '--owner' "$LANES_ERR" ||
    fail "#965 AC4: the warning must point at --owner: $(cat "$LANES_ERR")"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" || fail "#965 AC4: OK line missing"
  ! grep -q ' lane=' "$LANES_OUT" || fail "#965 AC4: nothing may be appended"
  echo "PASS 965-lanes AC4: missing --owner warns once and spawns unregistered"

  # AC5 — panewire refuses the lane (rc 5): the spawn still exits 0 with its
  # OK line, one warning carries 'hub lane not registered', and the receipt
  # stays free of hub_lane.
  WRK_PANEWIRE_LANES_RC=5 HERDR_SESSION=default lanes_spawn lane-ac5 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#965 AC5: a lanes refusal must not fail the spawn (rc=$LANES_RC)"
  [[ "$(grep -c '^add$' "$LANES_CALLS")" -eq 1 ]] ||
    fail "#965 AC5: the registration call must still be attempted once"
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#965 AC5: one 'hub lane not registered' warning expected: $(cat "$LANES_ERR")"
  grep -q '^OK pane=w:p1 ' "$LANES_OUT" || fail "#965 AC5: OK line missing"
  ! grep -q ' lane=' "$LANES_OUT" || fail "#965 AC5: a refused lane must not be printed"
  ! lanes_spawned_payload lane-ac5 | grep -q 'hub_lane' ||
    fail "#965 AC5: a refused lane must not land in job meta"
  echo "PASS 965-lanes AC5: lanes add rc!=0 warns and keeps the spawn"

  # AC7 — the credential files go to panewire as verbatim paths and are never
  # opened by wrk (they are chmod 000 here — a read would have died). The
  # secret values must appear in no output this feature produced.
  for output in "$TMP"/lanes-*.out "$TMP"/lanes-*.err; do
    if grep -Fq "$LANES_TOKEN_VALUE" "$output"; then
      fail "#965 AC7: the token env contents leaked into ${output##*/}"
    fi
    if grep -Fq "$LANES_CF_VALUE" "$output"; then
      fail "#965 AC7: the CF env contents leaked into ${output##*/}"
    fi
  done
  echo "PASS 965-lanes AC7: credential paths passed verbatim, contents unread"

  # AC6 — reap --apply removes exactly the recorded lane, only after the tab
  # close is confirmed; a dry run and a lane-less job call nothing.
  LANES_REAP_INBOX="$TMP/lanes-reap-inbox"
  LANES_REAP_HERDR_LOG="$TMP/lanes-reap-herdr.log"
  LANES_REAP_NOW="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).replace(microsecond=0).isoformat())')"
  lanes_reap_job lanes-reap-ok w1:p5 w1:t5 lane-965 lanes-reap-ok
  lanes_reap_job lanes-reap-plain w1:p6 w1:t6 lane-965 ''
  lanes_reap_job lanes-reap-fail w1:p7 w1:t7 lane-965-f lanes-reap-fail
  # The M3 mutant below reaps its own lane: the AC6 apply above already closed
  # lane-965's jobs, and a reaped job is never a candidate again.
  lanes_reap_job lanes-m3-ok w1:p8 w1:t8 lane-965-m3 lanes-m3-ok
  lanes_reap_job lanes-m3-plain w1:p10 w1:t10 lane-965-m3 ''

  lanes_reap_run dry --lane lane-965
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#965 AC6: dry run failed"
  [[ ! -e "$LANES_RM_LOG" ]] || fail "#965 AC6: a dry run must not call lanes rm"
  ! grep -q '^tab close ' "$LANES_REAP_HERDR_LOG" ||
    fail "#965 AC6: a dry run must not close a tab"
  grep -q '^would-close job=lanes-reap-ok ' "$LANES_REAP_OUT" ||
    fail "#965 AC6: the lane job must still be a dry-run candidate"
  echo "PASS 965-lanes AC6a: dry run registers no removal"

  # #994: rm now fires only after `lanes ls` confirms the row still belongs
  # to the recorded machine+pane — the apply case answers it with the
  # recorded route.
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lanes-reap-ok","machine":"mac-work-default","pane":"w1:p5","parent":"lane-965","sink":false}]}' \
    lanes_reap_run apply --lane lane-965 --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#965 AC6: apply failed: $(cat "$LANES_REAP_ERR")"
  python3 - "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", token_file, "--hub-cf-env", cf_file]
want = (["ls"] + creds + ["--"]
        + ["rm", "lanes-reap-ok"] + creds + ["--"])
assert got == want, "lanes ls+rm argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#965 AC6: reap must confirm the row with lanes ls, then rm exactly once, with the recorded lane and identical credentials"
  grep -q '^closed job=lanes-reap-ok ' "$LANES_REAP_OUT" ||
    fail "#965 AC6: the lane job must close: $(cat "$LANES_REAP_OUT")"
  grep -q '^closed job=lanes-reap-plain ' "$LANES_REAP_OUT" ||
    fail "#965 AC6: the lane-less job must still close: $(cat "$LANES_REAP_OUT")"
  echo "PASS 965-lanes AC6b: apply removes only the recorded lane"

  # A removal failure warns; the confirmed close still stands. `lanes ls`
  # confirms the row first, so LANES_RC still reaches the rm call (#994).
  WRK_PANEWIRE_LANES_RC=5 \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lanes-reap-fail","machine":"mac-work-default","pane":"w1:p7","parent":"lane-965-f","sink":false}]}' \
    lanes_reap_run rmfail --lane lane-965-f --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#965: reap apply must survive an rm failure"
  grep -q "wrk: warning: hub lane 'lanes-reap-fail' not removed" "$LANES_REAP_ERR" ||
    fail "#965: an rm failure must warn: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=lanes-reap-fail ' "$LANES_REAP_OUT" ||
    fail "#965: the pane must stay closed after an rm failure: $(cat "$LANES_REAP_OUT")"
  echo "PASS 965-lanes: lanes rm failure warns and the close stands"

  # -- assertion-RED mutants -------------------------------------------------
  # Each mutant kills one invariant; each run must produce the bad outcome the
  # matching assertion above rejects, proving the assertion is live.
  # M1: "a mapped session registers exactly one lane" — skip registration.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-skip \
    '  [[ "$ROLE" == worker ]] || return 0' \
    '  return 0'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-skip" HERDR_SESSION=default \
    lanes_spawn lane-ac1m --owner work-kairos
  if [[ -s "$LANES_CALLS" ]]; then
    fail "#965 M1 mutant survived: the lane was still registered"
  fi
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#965 M1 mutant survived: lane= still reached the OK line"
  echo "PASS 965-lanes M1: skipping registration goes RED"

  # M2: "registration failure never fails the spawn" — exit on lanes add rc!=0.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-fatal \
    '    warn "hub lane not registered (panewire lanes add exited $rc)"' \
    '    warn "hub lane not registered (panewire lanes add exited $rc)"; exit "$rc"'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-fatal" WRK_PANEWIRE_LANES_RC=5 \
    HERDR_SESSION=default lanes_spawn lane-ac5m --owner work-kairos
  [[ "$LANES_RC" -ne 0 ]] ||
    fail "#965 M2 mutant survived: the spawn still exited 0 after a refused lane"
  echo "PASS 965-lanes M2: failing the spawn on a lane refusal goes RED"

  # M3: "reap removes only the lane it registered" — rm for every closed job.
  # The mutant removes by job id and carries no expected machine/pane, so the
  # #994 `lanes ls` check must see rows that match empty wants (sink-shaped
  # rows) for the sweep to be observable at all.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-rmall \
    '        [[ -z "$hub_lane" ]] || hub_lane_remove "$hub_lane" "$hub_lane_machine" "$pane"' \
    '        hub_lane_remove "$job"'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-rmall" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lanes-m3-ok","machine":"","pane":"","parent":"","sink":true},{"lane":"lanes-m3-plain","machine":"","pane":"","parent":"","sink":true}]}' \
    lanes_reap_run rmall --lane lane-965-m3 --apply
  if ! grep -q 'lanes-m3-plain' "$LANES_RM_LOG" 2>/dev/null; then
    fail "#965 M3 mutant survived: the lane-less job was not swept"
  fi
  echo "PASS 965-lanes M3: removing every job lane goes RED"

  # ------------------------------------------------------------------
  # #994 — no unreapable rows, safe removal, clearer docs
  # ------------------------------------------------------------------
  # AC1 — the arbiter is absent (no job record, ARBITER_JOB_REGISTERED=0) on
  # a mapped session with --owner: zero lanes calls, one warning naming the
  # missing job record, spawn still rc 0. A lane registered here could never
  # be reaped, so registration must not happen.
  LANES_ARBITER_BIN="$TMP/absent-arbiter" HERDR_SESSION=default \
    lanes_spawn lane-994-ac1 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#994 AC1: arbiter-less spawn failed (rc=$LANES_RC): $(cat "$LANES_ERR")"
  lanes_assert_no_lanes_call lane-994-ac1
  [[ "$(grep -c 'wrk: warning: hub lane not registered' "$LANES_ERR")" -eq 1 ]] ||
    fail "#994 AC1: exactly one lane warning expected: $(cat "$LANES_ERR")"
  grep -q 'arbiter job record' "$LANES_ERR" ||
    fail "#994 AC1: the warning must name the missing job record: $(cat "$LANES_ERR")"
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#994 AC1: an unregistered lane must not reach the OK line"
  echo "PASS 994-lanes AC1: no job record, no lane"

  # AC2 — the job.spawned receipt write fails after the lane was registered:
  # one compensating `lanes rm` for that lane with the same credentials (a
  # `lanes ls` confirmation precedes it), one warning narrates the
  # deregistration, the spawn still exits 0.
  LANES_ARB_FAIL="$TMP/arbiter-fail-spawned"
# shellcheck disable=SC2016 # the printf template is wrapper source, not an expansion site
  printf '#!/usr/bin/env bash\nif [[ "$1" == event && " $* " == *" job.spawned "* ]]; then exit 3; fi\nexec "%s" "$@"\n' \
    "$ARBITER" >"$LANES_ARB_FAIL"
  chmod +x "$LANES_ARB_FAIL"
  LANES_ARBITER_BIN="$LANES_ARB_FAIL" HERDR_SESSION=default \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-ac2","machine":"mac-work-default","pane":"w:p1","parent":"work-kairos","sink":false}]}' \
    lanes_spawn lane-994-ac2 --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] ||
    fail "#994 AC2: a failed receipt must not fail the spawn (rc=$LANES_RC): $(cat "$LANES_ERR")"
  python3 - "$LANES_CALLS" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", token_file, "--hub-cf-env", cf_file]
want = (["add", "lane-994-ac2", "--machine", "mac-work-default", "--pane", "w:p1",
         "--parent", "work-kairos"] + creds + ["--"]
        + ["ls"] + creds + ["--"]
        + ["rm", "lane-994-ac2"] + creds + ["--"])
assert got == want, "compensation argv mismatch: got=%r want=%r" % (got, want)
PY
    fail "#994 AC2: exactly one lanes rm for the registered lane, with the same credentials"
  [[ "$(grep -c 'job.spawned receipt failed' "$LANES_ERR")" -eq 1 ]] ||
    fail "#994 AC2: the receipt failure must warn once: $(cat "$LANES_ERR")"
  [[ "$(grep -c 'deregistering it' "$LANES_ERR")" -eq 1 ]] ||
    fail "#994 AC2: one deregistration warning expected: $(cat "$LANES_ERR")"
  ! grep -q ' lane=' "$LANES_OUT" ||
    fail "#994 AC2: an unrecorded lane must not reach the OK line"
  echo "PASS 994-lanes AC2: a lost spawn receipt deregisters the lane"

  # AC3 — lane != job id != label (#965's fixture reused the job id as the
  # lane, which let a remove-by-job-id regression pass): `lanes rm` must
  # carry the recorded lane value and nothing else.
  lanes_reap_job j994-distinct w1:p11 w1:t11 own-994-d lane-994-distinct lbl-994-d
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-distinct","machine":"mac-work-default","pane":"w1:p11","parent":"x","sink":false}]}' \
    lanes_reap_run ac3 --lane own-994-d --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#994 AC3: apply failed: $(cat "$LANES_REAP_ERR")"
  python3 - "$LANES_RM_LOG" "$LANES_TOKEN_FILE" "$LANES_CF_FILE" <<'PY' ||
import sys
log, token_file, cf_file = sys.argv[1:]
try:
    got = open(log, encoding="utf-8").read().splitlines()
except OSError:
    raise SystemExit("no lanes call recorded")
creds = ["--hub-url", "https://hub.invalid",
         "--hub-token-env", token_file, "--hub-cf-env", cf_file]
want = (["ls"] + creds + ["--"]
        + ["rm", "lane-994-distinct"] + creds + ["--"])
assert got == want, "reap argv mismatch: got=%r want=%r" % (got, want)
for stray in ("j994-distinct", "lbl-994-d", "own-994-d"):
    assert stray not in got, "job/label/owner must never be an rm operand: %r" % stray
PY
    fail "#994 AC3: lanes rm must carry the recorded lane only"
  grep -q '^closed job=j994-distinct ' "$LANES_REAP_OUT" ||
    fail "#994 AC3: the job must close: $(cat "$LANES_REAP_OUT")"
  echo "PASS 994-lanes AC3: rm carries the recorded lane, never job/label"

  # AC4 — a flag-shaped (or otherwise invalid) lane value in the receipt
  # never reaches panewire argv: the name check fires before any lanes call,
  # one warning is logged and the pane still closes.
  lanes_reap_job j994-flag w1:p12 w1:t12 own-994-f --hub-url=x lbl-994-f
  lanes_reap_run ac4 --lane own-994-f --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] ||
    fail "#994 AC4: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j994-flag ' "$LANES_REAP_OUT" ||
    fail "#994 AC4: the pane must still close: $(cat "$LANES_REAP_OUT")"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF -- '--hub-url=x' "$LANES_RM_LOG" ||
      fail "#994 AC4: the flag-shaped lane reached panewire argv: $(cat "$LANES_RM_LOG")"
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#994 AC4: no lanes rm may run for an invalid lane: $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "hub lane '--hub-url=x' not removed" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#994 AC4: one invalid-name warning expected: $(cat "$LANES_REAP_ERR")"
  echo "PASS 994-lanes AC4: an invalid lane name never reaches panewire"

  # AC5 — `lanes ls` decides removal: a row moved to another pane is never
  # removed (a reused label must not lose the newer job's live row), a
  # matching machine+pane row is removed exactly once, and a failed listing
  # removes nothing (never remove blind).
  lanes_reap_job j994-moved w1:p13 w1:t13 own-994-m lane-994-moved lbl-994-m
  lanes_reap_job j994-match w1:p14 w1:t14 own-994-t lane-994-match lbl-994-t
  lanes_reap_job j994-lsfail w1:p15 w1:t15 own-994-l lane-994-lsfail lbl-994-l
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-moved","machine":"mac-work-default","pane":"w1:p99","parent":"x","sink":false}]}' \
    lanes_reap_run ac5a --lane own-994-m --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#994 AC5: apply failed: $(cat "$LANES_REAP_ERR")"
  grep -q '^closed job=j994-moved ' "$LANES_REAP_OUT" ||
    fail "#994 AC5: the pane must still close: $(cat "$LANES_REAP_OUT")"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#994 AC5: a moved row must not be removed: $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "lane now belongs to" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#994 AC5: one belongs-to-another-pane warning expected: $(cat "$LANES_REAP_ERR")"
  WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-match","machine":"mac-work-default","pane":"w1:p14","parent":"x","sink":false}]}' \
    lanes_reap_run ac5b --lane own-994-t --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#994 AC5: apply failed: $(cat "$LANES_REAP_ERR")"
  [[ "$(grep -cxF 'rm' "$LANES_RM_LOG")" -eq 1 &&
     "$(awk 'f{print; exit} /^rm$/{f=1}' "$LANES_RM_LOG")" == "lane-994-match" ]] ||
    fail "#994 AC5: exactly one lanes rm for the matching lane: $(cat "$LANES_RM_LOG")"
  WRK_PANEWIRE_LANES_LS_RC=7 lanes_reap_run ac5c --lane own-994-l --apply
  [[ "$LANES_REAP_RC" -eq 0 ]] || fail "#994 AC5: an ls failure must not fail the reap"
  grep -q '^closed job=j994-lsfail ' "$LANES_REAP_OUT" ||
    fail "#994 AC5: the pane must still close after an ls failure"
  if [[ -f "$LANES_RM_LOG" ]]; then
    ! grep -qxF 'rm' "$LANES_RM_LOG" ||
      fail "#994 AC5: a failed listing must never remove: $(cat "$LANES_RM_LOG")"
  fi
  [[ "$(grep -c "lanes ls exited 7" "$LANES_REAP_ERR")" -eq 1 ]] ||
    fail "#994 AC5: one ls-failure warning expected: $(cat "$LANES_REAP_ERR")"
  echo "PASS 994-lanes AC5: ls-confirmed removal only (moved/match/ls-fail)"

  # AC6 — a session_machine_ids value the one-line matcher cannot read warns
  # that the map could not be parsed; a parsed map without the session keeps
  # the old "no entry" wording (#965 AC2 above still asserts it).
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\n%s\n' \
    "$LANES_TOKEN_FILE" "session_machine_ids = { 'default' = 'mac-work-default' }" \
    >"$TMP/lanes-bad-squot.toml"
  printf '[hub]\nhub_url = "https://hub.invalid"\nhub_token_env = "%s"\nsession_machine_ids = {\n  "default" = "mac-work-default"\n}\n' \
    "$LANES_TOKEN_FILE" >"$TMP/lanes-bad-multiline.toml"
  LANES_CFG_OVERRIDE="$TMP/lanes-bad-squot.toml" HERDR_SESSION=default \
    lanes_spawn lane-994-squot --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#994 AC6: spawn failed on a bad map (rc=$LANES_RC)"
  lanes_assert_no_lanes_call lane-994-squot
  grep -q 'session_machine_ids value could not be parsed' "$LANES_ERR" ||
    fail "#994 AC6: single-quoted keys must warn could-not-be-parsed: $(cat "$LANES_ERR")"
  ! grep -q 'has no session_machine_ids entry' "$LANES_ERR" ||
    fail "#994 AC6: a bad map must not read as a missing entry: $(cat "$LANES_ERR")"
  LANES_CFG_OVERRIDE="$TMP/lanes-bad-multiline.toml" HERDR_SESSION=default \
    lanes_spawn lane-994-multi --owner work-kairos
  [[ "$LANES_RC" -eq 0 ]] || fail "#994 AC6: spawn failed on a multi-line map (rc=$LANES_RC)"
  grep -q 'session_machine_ids value could not be parsed' "$LANES_ERR" ||
    fail "#994 AC6: a multi-line table must warn could-not-be-parsed: $(cat "$LANES_ERR")"
  echo "PASS 994-lanes AC6: unparseable map warns could-not-be-parsed"

  # AC7 — the non-fleet-only sentence is in --help and the README (grep). The
  # help text is captured before grepping: a piped `grep -q` can exit on the
  # match while the writer still has output buffered, which pipefail reads as
  # a SIGPIPE failure.
  ac7_help_out="$("$WRK" spawn --help)"
  grep -qi 'session_machine_ids is for non-fleet herdr sessions' <<<"$ac7_help_out" ||
    fail "#994 AC7: spawn --help must carry the non-fleet sentence"
  grep -qi 'non-fleet' "$ROOT/README.md" ||
    fail "#994 AC7: README must carry the non-fleet sentence"
  echo "PASS 994-lanes AC7: docs say non-fleet sessions only"

  # -- #994 assertion-RED mutants -------------------------------------------
  # M1: "no lane without a receipt" — drop the arbiter gate; AC1's zero-call
  # assertion must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-994-nogate \
    '  if [[ "${ARBITER_JOB_REGISTERED:-0}" -ne 1 ]]; then' \
    '  if false; then'
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-994-nogate" \
    LANES_ARBITER_BIN="$TMP/absent-arbiter" HERDR_SESSION=default \
    lanes_spawn lane-994-m1 --owner work-kairos
  if [[ ! -s "$LANES_CALLS" ]]; then
    fail "#994 M1 mutant survived: no lanes add ran without a job record"
  fi
  echo "PASS 994-lanes M1: dropping the arbiter gate goes RED"

  # M2: "reap never removes another pane's lane" — skip the machine/pane
  # compare; AC5's no-rm assertion must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-994-blindrm \
    '  if [[ "$row_machine" != "$want_machine" || "$row_pane" != "$want_pane" ]]; then' \
    '  if false; then'
  lanes_reap_job j994-m2 w1:p16 w1:t16 own-994-m2 lane-994-m2 lbl-994-m2
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-994-blindrm" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"lane-994-m2","machine":"mac-work-default","pane":"w1:p88","parent":"x","sink":false}]}' \
    lanes_reap_run m2 --lane own-994-m2 --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF 'rm' "$LANES_RM_LOG"; then
    fail "#994 M2 mutant survived: the moved lane was not swept"
  fi
  echo "PASS 994-lanes M2: skipping the lanes ls compare goes RED"

  # M3: "only valid lane names reach panewire" — drop the name check in
  # hub_lane_remove; AC4's no-argv assertion must then fail.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
  devin_trust_mutant lanes-994-novalidate \
    '  if ! hub_lane_name_valid "$lane"; then' \
    '  if false; then'
  lanes_reap_job j994-m3 w1:p17 w1:t17 own-994-m3 --hub-url=x lbl-994-m3
  WRK_UNDER_TEST="$TMP/mut-wrk-lanes-994-novalidate" \
    WRK_PANEWIRE_LANES_LS='{"lanes":[{"lane":"--hub-url=x","machine":"mac-work-default","pane":"w1:p17","parent":"x","sink":false}]}' \
    lanes_reap_run m3 --lane own-994-m3 --apply
  if [[ ! -f "$LANES_RM_LOG" ]] || ! grep -qxF -- '--hub-url=x' "$LANES_RM_LOG"; then
    fail "#994 M3 mutant survived: the flag-shaped lane never reached argv"
  fi
  echo "PASS 994-lanes M3: dropping lane-name validation goes RED"
}

if [[ "${WRK_TEST_ONLY_LANES:-0}" -eq 1 ]]; then
  run_lanes_tests
  exit 0
fi
run_lanes_tests

arb() { "$ARBITER" "$@"; }

"$WRK" --help >/dev/null
spawn_help_out="$("$WRK" spawn --help)"
grep -q -- '--landing-strict' <<<"$spawn_help_out"
grep -q -- '--role worker|builder (legacy alias: captain)' <<<"$spawn_help_out"
grep -q -- 'builder-opus' <<<"$spawn_help_out"
grep -q -- 'builder-sonnet' <<<"$spawn_help_out" ||
  fail "spawn --help must document builder-sonnet (#921)"
# Task 612: the help text must document the kimi-code/ namespace and must not
# carry the retired kimi-for-coding/ prefix.
grep -q -- 'kimi --auto -m kimi-code/k3' <<<"$spawn_help_out" ||
  fail "spawn --help must document kimi-code/k3"
grep -q -- 'kimi --auto -m kimi-code/kimi-for-coding' <<<"$spawn_help_out" ||
  fail "spawn --help must document kimi-code/kimi-for-coding"
if grep -q 'kimi-for-coding/' <<<"$spawn_help_out"; then
  fail "spawn --help still carries the old kimi-for-coding/ namespace"
fi
reap_help_out="$("$WRK" reap --help)"
grep -q -- '--include-builders' <<<"$reap_help_out"
grep -q -- '--include-captains legacy alias' <<<"$reap_help_out"
"$WRK" find --help >/dev/null
"$WRK" name-sync --help >/dev/null
"$WRK" profiles --help >/dev/null
run_fail "$WRK" profiles --bogus
# #979: hosts called the never-defined hosts_help — --help and -h must print
# the usage and exit 0, while an unknown flag still dies as a usage error.
hosts_help_out="$("$WRK" hosts --help)"
grep -q 'Usage: wrk hosts' <<<"$hosts_help_out" ||
  fail "hosts --help must print the hosts usage: $hosts_help_out"
"$WRK" hosts -h >/dev/null || fail "hosts -h must exit 0"
run_fail "$WRK" hosts --bogus
run_fail "$WRK" hosts extra
run_fail "$WRK" spawn -c "$ROOT" -p "$PROMPT" -w w -l fixture
run_fail "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --bogus
run_fail "$WRK" nope

# ROB-1190 ④-2: wrk profiles — 기계 판독 가능한 프로필 목록. oc-omni 가 포함돼야 한다
# (드리프트 방지: scopefuel 이 추천하는데 wrk 가 못 띄우는 상태 방지).
profiles_out="$("$WRK" profiles)"
grep -qx 'oc-omni' <<<"$profiles_out"
grep -qx 'oc-solar4' <<<"$profiles_out"
grep -qx 'kimi-k3' <<<"$profiles_out"
grep -qx 'kimi-k27' <<<"$profiles_out"
grep -qx 'kimi-k27-code' <<<"$profiles_out"
grep -qx 'kimi-k3-low' <<<"$profiles_out"
grep -qx 'codex-terra-max' <<<"$profiles_out"
grep -qx 'builder-opus' <<<"$profiles_out"
grep -qx 'builder-sol' <<<"$profiles_out"
grep -qx 'builder-devin' <<<"$profiles_out"
grep -qx 'builder-devin-medium' <<<"$profiles_out"
grep -qx 'builder-devin-max' <<<"$profiles_out"
grep -qx 'builder-ds41' <<<"$profiles_out"
grep -qx 'builder-ds41-max' <<<"$profiles_out"
grep -qx 'builder-grok' <<<"$profiles_out"
grep -qx 'builder-kimi' <<<"$profiles_out"
grep -qx 'builder-luna' <<<"$profiles_out"
grep -qx 'builder-sonnet' <<<"$profiles_out" ||
  fail "wrk profiles lost builder-sonnet (#921)"
# #704 (#594 E6) + #737 (decision 4088): the per-rung builder spellings.
for e6_profile in builder-opus-low builder-opus-medium builder-sonnet-xhigh builder-sonnet-max \
  builder-sol-high builder-sol-max builder-sol-medium builder-luna-max \
  builder-terra-high builder-terra-xhigh builder-terra-max \
  builder-kimi-high builder-kimi-max \
  builder-grok-low builder-grok-medium builder-grok-xhigh; do
  grep -qx "$e6_profile" <<<"$profiles_out" || fail "wrk profiles lost $e6_profile"
done
grep -qx 'captain-opus' <<<"$profiles_out"
grep -qx 'captain-sol' <<<"$profiles_out"
grep -qx 'codex-astra' <<<"$profiles_out"
# ROB-591 rollback spellings (gpt-5.6-sol/gpt-5.6-luna) must remain spawnable.
grep -qx 'codex-sol56' <<<"$profiles_out"
grep -qx 'codex-luna56' <<<"$profiles_out"
# #1026 rollback spellings (gpt-6-sol) join the same list.
grep -qx 'codex-sol6' <<<"$profiles_out"
grep -qx 'builder-sol6' <<<"$profiles_out"
# task #526: the astra builder spellings were removed — astra is counsel-only
# (hk:doc decision/2026-09-21/astra-allowed-purposes-approved).
if grep -qx 'builder-astra' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'captain-astra' <<<"$profiles_out"; then exit 1; fi
[[ "$(grep -xc 'devin-swe2' <<<"$profiles_out")" -eq 1 ]]
grep -qx 'devin-glm52' <<<"$profiles_out"
grep -qx 'devin-swe17' <<<"$profiles_out"
grep -qx 'devin-ds41' <<<"$profiles_out"
# #635: the devin effort rungs are named profiles (effort sits inside the
# devin model id — no --effort flag exists). The scopefuel catalog lists all
# three, so the wrk⊇scopefuel cross-check needs them here.
grep -qx 'devin-swe2-medium' <<<"$profiles_out"
grep -qx 'devin-swe2-max' <<<"$profiles_out"
grep -qx 'devin-ds41-max' <<<"$profiles_out"
if grep -qx 'codex-ultra' <<<"$profiles_out"; then exit 1; fi
if grep -qx 'codex-luna-ultra' <<<"$profiles_out"; then exit 1; fi

name_out="$(WRK_FIXTURE_SCENARIO=find-name HERDR_BIN="$HERDR" "$WRK" find orch)"
grep -q 'pane_id=w:p1' <<<"$name_out"
grep -q 'ACTUAL SCREEN LAST LINE' <<<"$name_out"
[[ "$(WRK_FIXTURE_SCENARIO=find-name HERDR_BIN="$HERDR" "$WRK" find orch --pane-only)" == "w:p1" ]]
label_out="$(WRK_FIXTURE_SCENARIO=find-label HERDR_BIN="$HERDR" "$WRK" find target)"
grep -q 'match=label' <<<"$label_out"
grep -q 'pane_id=w:p2' <<<"$label_out"
run_fail env WRK_FIXTURE_SCENARIO=find-multi HERDR_BIN="$HERDR" "$WRK" find target
run_fail env WRK_FIXTURE_SCENARIO=find-multi HERDR_BIN="$HERDR" "$WRK" find target --pane-only
priority_out="$(WRK_FIXTURE_SCENARIO=name-priority HERDR_BIN="$HERDR" "$WRK" find target)"
grep -q 'pane_id=w:p1' <<<"$priority_out"
if grep -q 'pane_id=w:p2' <<<"$priority_out"; then exit 1; fi

mkdir -p "$TMP/home-old/.local/bin"
ln -s "$HERDR" "$TMP/home-old/.local/bin/herdr"
old_sync="$(HOME="$TMP/home-old" WRK_FIXTURE_SCENARIO=name-sync "$ROOT/bin/herdr-name-sync")"
new_sync="$(HERDR_BIN="$HERDR" WRK_FIXTURE_SCENARIO=name-sync "$WRK" name-sync)"
[[ "$old_sync" == "$new_sync" ]]
apply_sync="$(HERDR_BIN="$HERDR" WRK_FIXTURE_SCENARIO=name-sync "$WRK" name-sync build)"
grep -q "w:p3" <<<"$apply_sync"

: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
canonical_out="$(spawn_base codex-terra --effort max)"
grep -q 'codex-terra-max' "$TMP/scopefuel.log"
grep -q -- '-m gpt-5.6-terra' "$TMP/herdr.log"
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'model=codex-terra' <<<"$canonical_out"

profiles=(
  "opus:opus" "sonnet:sonnet" "sonnet-med:sonnet" "haiku:haiku"
  "devin-swe2:devin-swe2"
  "devin-glm52:devin-swe2" "devin-swe17:devin-swe2" "devin-ds41:devin-swe2"
  "devin-swe2-medium:devin-swe2" "devin-swe2-max:devin-swe2" "devin-ds41-max:devin-swe2"
  "codex:codex-max" "codex-sol:codex-max" "codex-med:codex-terra-max"
  "codex-luna:codex-luna-max" "codex-luna-hi:codex-luna-max"
  "codex-max:codex-max" "codex-terra:codex-terra-max"
  "codex-terra-max:codex-terra-max" "codex-luna-max:codex-luna-max"
  "codex-sol56:codex-max" "codex-luna56:codex-luna-max"
  "codex-sol6:codex-max"
  "kiro:kiro-sol" "kiro-opus:kiro-opus" "kiro-sonnet:kiro-sonnet"
  "kiro-sol:kiro-sol" "kiro-luna:kiro-sol" "kiro-cheap:kiro-cheap"
  "kiro-glm:kiro-sol" "kiro-deepseek:kiro-sol" "kiro-minimax:kiro-sol"
  "kiro-minimax21:kiro-sol" "kiro-haiku:kiro-haiku"
  "kiro-opus-xhigh:kiro-opus" "kiro-opus-max:kiro-opus"
  "kiro-sol-xhigh:kiro-sol" "kiro-sol-max:kiro-sol"
  "kimi-k3:kimi-k3" "kimi-k27:kimi-k27" "kimi-k27-code:kimi-k27-code" "kimi-k3-low:kimi-k3-low"
  "oc-kimi-code:oc-kimi-code" "oc-glm:oc-glm" "oc-kimi-k3:oc-kimi-k3"
  "oc-dsflash:oc-dsflash" "oc-gflash:oc-gflash" "oc-sonnet46:oc-sonnet46"
  "oc-oss:oc-oss" "oc-omni:oc-omni" "oc-qwen37-max:oc-qwen37-max"
  "oc-minimax-m3:oc-minimax-m3" "oc-solar4:oc-solar4" "grok:grok-hi" "grok-hi:grok-hi" "grok-med:grok-hi" "grok45:grok-hi" "grok45-med:grok-hi" "grok46:grok-hi" "grok46-med:grok-hi"
  "cc-qwen38:cc-qwen38" "cc-glm:cc-glm"
  "cc-dsflash:cc-qwen38" "cc-dspro:cc-qwen38" "cc-glm53:cc-qwen38"
  )
for pair in "${profiles[@]}"; do
  runtime="${pair%%:*}"
  expected="${pair#*:}"
  : >"$TMP/scopefuel.log"
  : >"$TMP/herdr.log"
  spawn_base "$runtime" >/dev/null
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "$expected" ]]
done
# #593: fable is consult_only in the catalog, so it is no longer a plain entry
# in the table above — a bare spawn is refused even when the quota gate allows
# it. Its gate spelling is still part of the contract, asserted with the
# operator request that makes the launch legal.
: >"$TMP/scopefuel.log"
: >"$TMP/herdr.log"
spawn_base fable --operator-request hk:doc/decision/2026-09-21/astra-allowed-purposes-approved \
  --requested-by operator >/dev/null
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == fable ]]
: >"$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --t T1

run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m agy -p "$PROMPT" -w w -l fixture

# Task 577: Devin temporarily bypasses Herdr 0.9.1's failing agent-start
# ownership check. The fixture pins the exact pane-id run -> bounded welcome
# wait -> explain identity -> pane-id rename sequence, and no prompt/effort
# mutation is smuggled into the Devin process. Permission mode is intentionally
# unattended (`--permission-mode dangerous`): accept-edits prompts on every
# shell command in a pane and stalls (task201). Task 240 later admitted the
# same profile under --role builder (pilot) without changing this argv.
: >"$TMP/herdr.log"
# The fake clock below answers every `date +%s` with 1000 until the first
# herdr call matching FAKECLOCK_AFTER is logged, then 1000+FAKECLOCK_JUMP
# (#606).
# With FAKECLOCK_JUMP=0 it is frozen, so the attempt cap — not how fast this
# host runs 120 fixture calls — is what ends a never-ready poll.
mkdir -p "$TMP/jumpclock"
cat >"$TMP/jumpclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  seen="$(grep -c "^$FAKECLOCK_AFTER" "$WRK_FIXTURE_LOG" 2>/dev/null || true)"
  if (( ${seen:-0} >= 1 )); then echo $(( 1000 + FAKECLOCK_JUMP )); else echo 1000; fi
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/jumpclock/date"
# #979 N1: the substitution must be guarded — when every probe read fails the
# spawn exits nonzero and an unguarded $(...) dies silently under set -e.
devin_idle_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 2>&1)" ||
  fail "devin-idle spawn failed: $devin_idle_out"
grep -q 'model=devin-swe2' <<<"$devin_idle_out"
grep -q 'status=idle' <<<"$devin_idle_out"
grep -q 'landed=yes' <<<"$devin_idle_out"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
devin_run_line="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
[[ "$devin_run_line" == 'pane run w:p1 devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' ]] ||
  fail "devin pane-run argv snapshot mismatch: $devin_run_line"
# Detection and the idle wait share one 30s window, so the wait gets what is
# left of it (whole seconds; never more than 30000ms). The clock is frozen so
# host speed cannot move the value (#606: the shell-ready poll now also runs
# inside the window, and on a loaded host 2-3s had already passed).
devin_wait_line="$(grep '^agent wait ' "$TMP/herdr.log")"
if ! [[ "$devin_wait_line" =~ ^agent\ wait\ w:p1\ --until\ idle\ --timeout\ ([0-9]+)$ ]] ||
   (( BASH_REMATCH[1] != 30000 )); then
  fail "devin welcome wait argv drifted: $devin_wait_line"
fi
grep -qx 'agent get w:p1' "$TMP/herdr.log" ||
  fail "devin detection poll must query the tab-create pane id"
grep -qx 'agent explain w:p1 --format json' "$TMP/herdr.log" ||
  fail "devin explain argv drifted"
grep -qx 'agent rename w:p1 fixture' "$TMP/herdr.log" ||
  fail "devin rename must target tab-create pane id, never a name lookup"
if grep -q '^agent start .*--kind devin' "$TMP/herdr.log"; then
  fail "devin workaround must not call agent start"
fi
devin_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
devin_get_no="$(grep -n '^agent get ' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
(( devin_run_no < devin_get_no )) || fail "devin detection poll must follow pane run"
devin_wait_no="$(grep -n '^agent wait ' "$TMP/herdr.log" | cut -d: -f1)"
devin_explain_no="$(grep -n '^agent explain ' "$TMP/herdr.log" | cut -d: -f1)"
devin_rename_no="$(grep -n '^agent rename ' "$TMP/herdr.log" | cut -d: -f1)"
devin_prompt_no="$(grep -n '^agent prompt .*fixture prompt' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
(( devin_run_no < devin_wait_no && devin_wait_no < devin_explain_no &&
   devin_explain_no < devin_rename_no && devin_rename_no < devin_prompt_no )) ||
  fail "devin startup order must be run < wait < explain < rename < brief"
[[ " $devin_run_line " != *' -p '* ]] || fail "devin run argv must not contain -p"
[[ " $devin_run_line " != *' --dangerously-skip-permissions '* ]] || fail "devin run argv must not contain Claude-only --dangerously-skip-permissions"
[[ " $devin_run_line " != *' --effort '* ]] || fail "devin run argv must not contain effort"
# Pin README's documented argv to the live snapshot. Read README; do not
# hardcode a second expected string (that would just grow the drift surface).
# shellcheck disable=SC2016  # the backtick is literal markdown, not a substitution
readme_devin_argv="$(sed -n 's/.*`herdr pane run <pane_id> devin \(--model swe-2 .* --respect-workspace-trust false\)`.*/\1/p' "$ROOT/README.md")"
[[ -n "$readme_devin_argv" && "$(grep -c . <<<"$readme_devin_argv")" -eq 1 ]] ||
  fail "README.md has no unique documented devin argv to pin against the snapshot"
devin_snapshot_argv="${devin_run_line#pane run w:p1 devin }"
[[ "$readme_devin_argv" == "$devin_snapshot_argv" ]] ||
  fail "README.md argv drifted from wrk snapshot: readme='$readme_devin_argv' snapshot='$devin_snapshot_argv'"

# Task 577 FIX: right after `pane run` herdr has not yet detected the pane, so
# agent get/wait/explain answer agent_not_found (16:44 probe2). Inside the
# window that is "not detected yet": poll `agent get` on the created pane id,
# and only after detection wait for idle, check identity and rename. Reverting
# agent_not_found to an immediate failure turns this case red.
: >"$TMP/herdr.log"
devin_late_out="$(TEST_FIXTURE_SCENARIO=devin-late-detect spawn_base devin-swe2 2>&1)" ||
  fail "Devin detected on the fourth poll must still spawn: $devin_late_out"
grep -q 'landed=yes' <<<"$devin_late_out" || fail "late-detected Devin did not land: $devin_late_out"
devin_late_first_wait="$(grep -n '^agent wait ' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
[[ "$(head -n "$devin_late_first_wait" "$TMP/herdr.log" | grep -c '^agent get w:p1$')" -eq 4 ]] ||
  fail "late-detected Devin must poll get until detection before waiting"
grep -qx 'agent rename w:p1 fixture' "$TMP/herdr.log" ||
  fail "late-detected Devin must rename the tab-create pane id"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "late-detected Devin must receive exactly one brief"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "late-detected Devin pane was closed"; fi

# Mutants for the ownership substitute: skipping the bounded wait/explain,
# accepting another detected agent/rule, or renaming after timeout must all be
# red. Every failure records process-info and lets the existing pane cleanup run.
devin_readiness_failure_case() {
  local scenario="$1" want_rc="$2" out rc
  : >"$TMP/herdr.log"
  set +e
  # Frozen clock (#606): the attempt cap, not host speed, ends never-detect.
  out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO="$scenario" spawn_base devin-swe2 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq "$want_rc" ]] ||
    fail "$scenario expected rc=$want_rc, got rc=$rc: $out"
  grep -qx 'pane run w:p1 devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' "$TMP/herdr.log" ||
    fail "$scenario did not use the created pane id"
  if grep -q '^agent rename ' "$TMP/herdr.log"; then
    fail "$scenario renamed an unowned/unready pane"
  fi
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then
    fail "$scenario delivered a brief before ownership/readiness"
  fi
  sed -n '/^pane run /,$p' "$TMP/herdr.log" | grep -qx 'pane process-info --pane w:p1' ||
    fail "$scenario omitted failure process diagnostics"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
    fail "$scenario leaked the failed pane"
  DEVIN_CASE_OUT="$out"
}
devin_readiness_failure_case devin-wait-timeout 7
devin_readiness_failure_case devin-wrong-agent 1
devin_readiness_failure_case devin-wrong-rule 1
# Task 577 SHOULD (first-round tester): every remaining diagnostic branch is
# pinned by its own fixture failure.
devin_readiness_failure_case devin-run-fail 5
devin_readiness_failure_case devin-get-error 1
grep -q 'agent get exited 1 before detection' <<<"$DEVIN_CASE_OUT" ||
  fail "non-agent_not_found get error lost its diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent get w:p1$' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "non-agent_not_found get error must fail on the first get, not be retried"
devin_readiness_failure_case devin-explain-fail 4
devin_readiness_failure_case devin-explain-garbage 1
grep -q 'agent explain returned an invalid identity envelope' <<<"$DEVIN_CASE_OUT" ||
  fail "malformed explain JSON lost its diagnostic: $DEVIN_CASE_OUT"

# #604: the 2026-09-23 incident shape — explain answers a well-formed envelope
# whose matched_rule is absent because no identity rule claimed the screen
# (first-open trust prompt hypothesis). Since #649 this bare envelope carries
# no evaluated_rules proving the screen is just the command line, so it is an
# "unmatched" screen: polled to the window, then the spawn still fails and
# the pane's screen, transcript, explain JSON and process-info must survive
# the pane.
devin_readiness_failure_case devin-explain-no-rule 1
grep -q 'agent explain matched no identity rule within 30000ms (unmatched screen x120)' <<<"$DEVIN_CASE_OUT" ||
  fail "no-rule explain lost the bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "no-rule explain must poll to the 30000/250 attempt cap"
grep -q 'Devin spawn failure artifacts preserved under ' <<<"$DEVIN_CASE_OUT" ||
  fail "604 failure artifacts were not announced: $DEVIN_CASE_OUT"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 artifact dir missing: $artifact_dir"
[[ "$artifact_dir" == "$TMP/inbox/fixture/devin-spawn-failure-"* ||
   "$artifact_dir" == "$(cd "$TMP" && pwd -P)/inbox/fixture/devin-spawn-failure-"* ]] ||
  fail "604 artifacts must live in the job dir: $artifact_dir"
grep -q 'reason=agent explain matched no identity rule within 30000ms' "$artifact_dir/reason.txt" ||
  fail "604 reason.txt lost the failure reason"
grep -q '"matched_rule":null' "$artifact_dir/explain.out" ||
  fail "604 the explain envelope that failed was not preserved"
grep -q 'fixture welcome screen' "$artifact_dir/screen-visible.txt" ||
  fail "604 visible screen was not preserved"
grep -q 'fixture welcome screen' "$artifact_dir/transcript.txt" ||
  fail "604 transcript was not preserved"
grep -q 'pane_id' "$artifact_dir/process-info.out" ||
  fail "604 process-info was not preserved"
# The jobs root is scanned for event envelopes with rglob("*.json"); a raw
# capture that is not an event envelope must not carry the .json extension
# (a 'not json at all' explain.out broke exactly that scan on CI 2026-09-24).
if find "$artifact_dir" -name '*.json' | grep -q .; then
  fail "604 artifact dir must not contain .json files: $artifact_dir"
fi
echo "PASS 604-explain-no-rule-artifacts-preserved"

# #604 hypothesis variant: a rule did match — the trust prompt — so the spawn
# fails on the rule id, and the preserved visible screen carries the actual
# cause the pane was showing.
devin_readiness_failure_case devin-trust-screen 1
grep -q 'expected agent=devin rule=welcome_prompt_footer, got agent=devin rule=trust_directory' <<<"$DEVIN_CASE_OUT" ||
  fail "trust-screen explain lost its rule diagnostic: $DEVIN_CASE_OUT"
# #649: a matched non-welcome rule is a terminal state — judged on the first
# explain, never polled (a mutant that retries matched rules turns this red).
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "trust-screen must be judged on the first explain, not polled"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 trust-screen artifact dir missing"
grep -q 'trust_directory' "$artifact_dir/explain.out" ||
  fail "604 trust-screen explain.out was not preserved"
grep -q 'Do you trust the contents of this directory?' "$artifact_dir/screen-visible.txt" ||
  fail "604 trust-screen visible capture lost the prompt"
echo "PASS 604-trust-screen-artifacts-preserved"

# #604: preservation also covers the non-explain failures, and a failed
# capture must never mask the spawn failure it documents. explain-fail leaves
# explain.rc=4 instead of a stolen success.
devin_readiness_failure_case devin-explain-fail 4
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" && -f "$artifact_dir/explain.rc" ]] ||
  fail "604 explain-fail must still leave an artifact dir: $DEVIN_CASE_OUT"
grep -qx 'rc=4' "$artifact_dir/explain.rc" ||
  fail "604 explain-fail must record the explain rc: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"
echo "PASS 604-explain-fail-artifacts-preserved"

# #604 (CodeRabbit major on PR #122): explain answering rc=0 with EMPTY stdout
# is a supplied failing response, not an absent one. Preservation must save
# that response verbatim (a 0-byte explain.out plus an explicit rc=0) and must
# not re-query — a second explain would overwrite the artifact with a later,
# different response (the fixture answers a valid envelope from call 2 on, so
# a re-querying mutant turns this red).
devin_readiness_failure_case devin-explain-empty 1
grep -q 'agent explain returned an invalid identity envelope' <<<"$DEVIN_CASE_OUT" ||
  fail "empty explain response lost the invalid-envelope diagnostic: $DEVIN_CASE_OUT"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 explain-empty artifact dir missing: $DEVIN_CASE_OUT"
[[ -f "$artifact_dir/explain.out" && ! -s "$artifact_dir/explain.out" ]] ||
  fail "604 explain-empty must preserve the empty response verbatim: $(ls -l "$artifact_dir" 2>/dev/null)"
grep -qx 'rc=0' "$artifact_dir/explain.rc" ||
  fail "604 explain-empty must record the supplied explain rc=0: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "604 explain-empty must not re-query explain over the failing response"
echo "PASS 604-explain-empty-response-preserved"

# #604 (tester round 1): a pre-detection failure must not query agent
# endpoints, but it still owes the artifact set an explicit explain outcome —
# rc=skipped, not an absent file that reads as "preservation forgot it".
devin_readiness_failure_case devin-get-error 1
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 get-error artifact dir missing: $DEVIN_CASE_OUT"
grep -qx 'rc=skipped' "$artifact_dir/explain.rc" ||
  fail "604 pre-detection failure must record explain rc=skipped: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"
echo "PASS 604-pre-detection-explain-skip-recorded"

# #604 (tester round 1, minor): a failed pane-read capture must not mask,
# replace or worsen the spawn failure it documents — rc stays 1 and the rest
# of the artifact set is still written.
devin_readiness_failure_case devin-read-fail 1
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 read-fail artifact dir missing: $DEVIN_CASE_OUT"
grep -qx 'rc=9' "$artifact_dir/screen-visible.rc" ||
  fail "604 read-fail must record the capture rc: $(cat "$artifact_dir/screen-visible.rc" 2>/dev/null)"
grep -q '"matched_rule":null' "$artifact_dir/explain.out" ||
  fail "604 read-fail must still preserve the explain envelope"
echo "PASS 604-capture-failure-does-not-mask-spawn-rc"

devin_readiness_failure_case devin-never-detect 1
grep -q "Devin pane startup failed: agent not detected within 30000ms (agent_not_found x120)" <<<"$DEVIN_CASE_OUT" ||
  fail "never-detected Devin lost its bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent get w:p1$' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "never-detected Devin must poll exactly the 30000/250 attempt cap"
if grep -q '^agent wait \|^agent explain ' "$TMP/herdr.log"; then
  fail "never-detected Devin waited or explained an undetected pane"
fi
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "604 never-detect artifact dir missing: $DEVIN_CASE_OUT"
grep -qx 'rc=skipped' "$artifact_dir/explain.rc" ||
  fail "604 never-detect must record explain rc=skipped: $(cat "$artifact_dir/explain.rc" 2>/dev/null)"

# #649 (m1b): a slow devin reaches the identity check before its TUI is
# painted — explain answers a well-formed envelope with every rule unmatched
# and the evaluated region still holds only the typed command line. That is
# "still starting", not a spawn failure: explain is re-polled with backoff
# inside the same START_TIMEOUT window. A mutant that fails on the first
# unmatched envelope turns the success assertion red.
: >"$TMP/herdr.log"
devin_starting_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=devin-explain-starting spawn_base devin-swe2 2>&1)" ||
  fail "still-starting Devin must spawn once the welcome footer appears: $devin_starting_out"
grep -q 'landed=yes' <<<"$devin_starting_out" ||
  fail "still-starting Devin did not land: $devin_starting_out"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 4 ]] ||
  fail "starting Devin must poll explain until a rule matches: $(grep -c '^agent explain ' "$TMP/herdr.log")"
grep -qx 'agent rename w:p1 fixture' "$TMP/herdr.log" ||
  fail "still-starting Devin must rename the tab-create pane id"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "still-starting Devin must receive exactly one brief"
echo "PASS 649-starting-polls-then-succeeds"

# The same command-line-only screen that never resolves: the window closes
# and the spawn fails closed with the #604 artifact set and a reason naming
# the still-starting shape — "on timeout, the existing fail-closed path".
devin_readiness_failure_case devin-explain-starting-stuck 1
grep -q 'Devin pane startup failed: agent explain still starting within 30000ms (command-line-only screen x120)' <<<"$DEVIN_CASE_OUT" ||
  fail "never-starting Devin lost its bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "never-starting Devin must poll explain exactly the 30000/250 attempt cap"
artifact_dir="$(sed -n 's/.*Devin spawn failure artifacts preserved under \(.*\)/\1/p' <<<"$DEVIN_CASE_OUT" | head -n1)"
[[ -d "$artifact_dir" ]] || fail "649 starting-stuck artifact dir missing: $artifact_dir"
grep -q '"matched_rule":null' "$artifact_dir/explain.out" ||
  fail "649 starting-stuck must preserve the last explain envelope"
echo "PASS 649-starting-window-fails-closed"

# Unknown screen — unmatched rules AND the evaluated region is not the
# command line: also rides the window out, then fails ("fail after the
# window"), distinct from a matched dialog's immediate judgement. A mutant
# that fails it on the first explain turns the poll-count assertion red.
devin_readiness_failure_case devin-explain-unknown 1
grep -q 'Devin pane startup failed: agent explain matched no identity rule within 30000ms (unmatched screen x120)' <<<"$DEVIN_CASE_OUT" ||
  fail "unknown-screen Devin lost its bounded-window diagnostic: $DEVIN_CASE_OUT"
[[ "$(grep -c '^agent explain ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "unknown-screen Devin must poll explain exactly the 30000/250 attempt cap"
echo "PASS 649-unknown-screen-window-fails-closed"

# Detection on the window edge: a fake clock (only `date +%s` is faked) puts
# the window deadline between detection and the idle wait. Detection succeeds
# on the first get, but no time is left, so wrk must fail before agent wait
# instead of handing it a zero or negative timeout.
mkdir -p "$TMP/fakeclock"
# #979: the readiness probe adds one `date +%s` call to the start path — the
# readiness loop's deadline check on the iteration that sends the probe —
# so the clock now stays in-window for the first two calls (started_at, the
# probe-send iteration) and jumps on the third: the post-detection
# remaining_ms check, or the first failed get's deadline check.
cat >"$TMP/fakeclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  calls=0
  [[ -e "$FAKECLOCK_STATE" ]] && calls="$(cat "$FAKECLOCK_STATE")"
  calls=$(( calls + 1 ))
  printf '%s\n' "$calls" >"$FAKECLOCK_STATE"
  if (( calls > ${FAKECLOCK_AFTER_CALLS:-2} )); then echo 1031; else echo 1000; fi
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/fakeclock/date"
: >"$TMP/herdr.log"
rm -f "$TMP/fakeclock.state"
set +e
devin_edge_out="$(PATH="$TMP/fakeclock:$PATH" FAKECLOCK_STATE="$TMP/fakeclock.state" TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 2>&1)"
devin_edge_rc=$?
set -e
[[ "$devin_edge_rc" -eq 1 ]] || fail "window-edge Devin detection expected rc=1, got $devin_edge_rc: $devin_edge_out"
grep -q 'Devin pane startup failed: agent detected after the 30000ms window' <<<"$devin_edge_out" ||
  fail "window-edge Devin detection lost its diagnostic: $devin_edge_out"
if grep -q '^agent wait \|^agent rename \|^agent prompt ' "$TMP/herdr.log"; then
  fail "window-edge Devin detection waited, renamed or delivered past the window"
fi
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "window-edge Devin detection leaked its pane"

# The wall clock, not the attempt cap, is what bounds the window in
# production (verify1 E1: 97 gets in 30s). With the same fake clock, the first
# agent_not_found is already past the window: wrk must stop after that one get,
# long before the 120-attempt cap, and never wait or rename.
: >"$TMP/herdr.log"
rm -f "$TMP/fakeclock.state"
set +e
devin_clock_out="$(PATH="$TMP/fakeclock:$PATH" FAKECLOCK_STATE="$TMP/fakeclock.state" TEST_FIXTURE_SCENARIO=devin-never-detect spawn_base devin-swe2 2>&1)"
devin_clock_rc=$?
set -e
[[ "$devin_clock_rc" -eq 1 ]] || fail "wall-clock-bounded Devin detection expected rc=1, got $devin_clock_rc: $devin_clock_out"
grep -q 'agent not detected within 30000ms (agent_not_found x1)' <<<"$devin_clock_out" ||
  fail "wall-clock bound did not stop the detection poll: $devin_clock_out"
[[ "$(grep -c '^agent get w:p1$' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "wall-clock bound must stop polling at the first get past the window"
if grep -q '^agent wait \|^agent rename \|^agent prompt ' "$TMP/herdr.log"; then
  fail "wall-clock-bounded Devin detection waited, renamed or delivered"
fi

# SHOULD-1 (first-round tester): a rename failure must record diagnostics for
# the renamed pane and deliver nothing.
: >"$TMP/herdr.log"
set +e
devin_rename_out="$(TEST_FIXTURE_SCENARIO=devin-rename-fail spawn_base devin-swe2 2>&1)"
devin_rename_rc=$?
set -e
[[ "$devin_rename_rc" -eq 6 ]] || fail "devin rename failure expected rc=6, got $devin_rename_rc: $devin_rename_out"
grep -q 'Devin pane startup failed: agent rename exited 6; pane=w:p1' <<<"$devin_rename_out" ||
  fail "devin rename failure lost its diagnostic: $devin_rename_out"
devin_rename_no="$(grep -n '^agent rename w:p1 fixture$' "$TMP/herdr.log" | cut -d: -f1)"
devin_info_no="$(grep -n '^pane process-info --pane w:p1$' "$TMP/herdr.log" | tail -n1 | cut -d: -f1)"
if [[ -z "$devin_rename_no" || -z "$devin_info_no" ]] || (( devin_rename_no > devin_info_no )); then
  fail "devin rename failure must record process-info after the failed rename"
fi
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "devin rename failure leaked its pane"
if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "devin rename failure delivered a brief"; fi
echo "PASS task577 Devin detection poll, bounded window and failure diagnostics"

# The devin branch remains behind the unchanged gate. A refusal preserves the
# gate rc and reaches neither tab creation nor pane run.
rm -f "$TMP/herdr.log"
set +e
devin_gate_out="$(WRK_GATE_MODE=3 spawn_base devin-swe2 2>&1)"
devin_gate_rc=$?
set -e
[[ "$devin_gate_rc" -eq 3 ]] ||
  fail "devin gate refusal rc drifted (rc=$devin_gate_rc): $devin_gate_out"
[[ ! -e "$TMP/herdr.log" ]] || fail "devin gate refusal reached Herdr"

# Every other kind keeps the generic `agent start` path exactly.
: >"$TMP/herdr.log"
spawn_base codex-terra >/dev/null
grep -qx 'agent start fixture --kind codex --pane w:p1 --timeout 120000 -- --yolo -m gpt-5.6-terra -c model_reasoning_effort=medium' "$TMP/herdr.log" ||
  fail "non-Devin agent-start path drifted"
if grep -q '^pane run ' "$TMP/herdr.log"; then fail "non-Devin kind reached pane run"; fi

# #606: a fresh pane whose shell is still running rc subprocesses answers
# `agent start` with agent_pane_busy (real herdr 0.9.0 envelope, stderr, rc=1).
# Inside the START_TIMEOUT window that is retried with the 250ms poll; every
# other start failure still fails at once. Removing the retry turns the
# shell-busy cases red; retrying every error turns the non-busy cases red.
for shell_busy_pair in "opus:claude" "codex-terra:codex"; do
  shell_busy_model="${shell_busy_pair%%:*}"
  shell_busy_kind="${shell_busy_pair#*:}"
  : >"$TMP/herdr.log"
  shell_busy_out="$(TEST_FIXTURE_SCENARIO=shell-busy spawn_base "$shell_busy_model" 2>&1)" ||
    fail "$shell_busy_model: shell ready on the fourth start must still spawn: $shell_busy_out"
  grep -q '^OK pane=w:p1' <<<"$shell_busy_out" ||
    fail "$shell_busy_model: late shell did not reach the OK line: $shell_busy_out"
  grep -q 'landed=yes' <<<"$shell_busy_out" ||
    fail "$shell_busy_model: late shell brief did not land: $shell_busy_out"
  [[ "$(grep -c "^agent start fixture --kind $shell_busy_kind --pane w:p1 " "$TMP/herdr.log")" -eq 4 ]] ||
    fail "$shell_busy_model: agent_pane_busy x3 must be retried on the tab-create pane until accepted"
  [[ "$(grep -c '"code":"agent_pane_busy"' <<<"$shell_busy_out")" -eq 3 ]] ||
    fail "$shell_busy_model: each busy refusal must stay visible on stderr: $shell_busy_out"
  [[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$shell_busy_model: late shell must receive exactly one brief"
  first_prompt_no="$(grep -n '^agent prompt ' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
  last_start_no="$(grep -n '^agent start ' "$TMP/herdr.log" | tail -n1 | cut -d: -f1)"
  (( last_start_no < first_prompt_no )) || fail "$shell_busy_model: brief delivered before the accepted start"
  if grep -q '^pane close ' "$TMP/herdr.log"; then fail "$shell_busy_model: late-shell pane was closed"; fi
done

# A shell that never frees the foreground fails closed at the window: the
# attempt cap bounds the loop when sleep is disabled (30000/250 for Claude),
# the pane is closed and no brief is delivered.
: >"$TMP/herdr.log"
set +e
shell_never_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=shell-never-ready spawn_base opus 2>&1)"
shell_never_rc=$?
set -e
[[ "$shell_never_rc" -eq 1 ]] || fail "never-ready shell expected rc=1, got $shell_never_rc: $shell_never_out"
grep -q 'agent start failed: shell not ready within the 30000ms window (agent_pane_busy x120); pane=w:p1' <<<"$shell_never_out" ||
  fail "never-ready shell lost its bounded-window diagnostic: $shell_never_out"
[[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 120 ]] ||
  fail "never-ready shell must stop at the 30000/250 attempt cap"
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "never-ready shell leaked its pane"
if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "never-ready shell delivered a brief"; fi

# Non-busy start failures keep failing on the first attempt with herdr's rc.
for shell_err_pair in "start-not-ready:1:agent_not_ready" "start-pane-unavailable:3:agent_pane_unavailable"; do
  IFS=: read -r shell_err_scenario shell_err_rc shell_err_code <<<"$shell_err_pair"
  : >"$TMP/herdr.log"
  set +e
  shell_err_out="$(TEST_FIXTURE_SCENARIO="$shell_err_scenario" spawn_base opus 2>&1)"
  shell_err_got=$?
  set -e
  [[ "$shell_err_got" -eq "$shell_err_rc" ]] ||
    fail "$shell_err_scenario expected rc=$shell_err_rc, got $shell_err_got: $shell_err_out"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "$shell_err_scenario must not be retried"
  grep -q "\"code\":\"$shell_err_code\"" <<<"$shell_err_out" ||
    fail "$shell_err_scenario lost herdr's error envelope: $shell_err_out"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "$shell_err_scenario leaked its pane"
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "$shell_err_scenario delivered a brief"; fi
done

# #609: an accepted `agent start` whose binary never reaches the pane
# foreground — the m1b shape, zsh answered "command not found: codex" — must
# not receive a brief. Before any injection wrk polls process-info until a
# foreground process's argv0 is the kind's canonical executable; the shell
# alone, a shell child or an unrelated process are all "not the agent", and
# the bounded window ends in fail-closed: pane closed, zero injections through
# either path (panewire prompt or a direct agent prompt/send-keys).
FG_PW_LOG="$TMP/foreground-panewire.log"
fg_failure_case() {
  local model="$1" scenario="$2" want_rc="$3" out rc
  : >"$TMP/herdr.log"
  rm -f "$FG_PW_LOG" "$FG_PW_LOG".*
  set +e
  out="$(WRK_PANEWIRE_PROMPT_LOG="$FG_PW_LOG" TEST_FIXTURE_SCENARIO="$scenario" spawn_base "$model" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq "$want_rc" ]] ||
    fail "$model/$scenario expected rc=$want_rc, got rc=$rc: $out"
  grep -q 'agent foreground check failed:' <<<"$out" ||
    fail "$model/$scenario lost its foreground diagnostic: $out"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
    fail "$model/$scenario leaked the agent-less pane"
  if grep -q '^agent prompt \|^agent send-keys \|^pane run .*-p\b' "$TMP/herdr.log"; then
    fail "$model/$scenario injected into a pane without its agent"
  fi
  [[ ! -e "$FG_PW_LOG" ]] ||
    fail "$model/$scenario delivered a panewire prompt without its agent"
  FG_CASE_OUT="$out"
}

# The bare shell in the foreground is the incident shape, for a start-path
# kind and for Devin's pane-run path alike.
fg_failure_case opus agent-never-foreground 1
grep -q 'agent not foreground within 10000ms (not-foreground x40)' <<<"$FG_CASE_OUT" ||
  fail "never-foreground claude lost its bounded-window diagnostic: $FG_CASE_OUT"
[[ "$(grep -c '^pane process-info --pane w:p1' "$TMP/herdr.log")" -eq 41 ]] ||
  fail "never-foreground claude must stop at the 10000/250 cap plus one diagnostic"
fg_failure_case codex-terra agent-never-foreground 1
fg_failure_case devin-swe2 agent-never-foreground 1
# kiro's pre-brief /effort prompt is also an injection; the gate precedes it.
# (`agent start` argv legitimately carries `--effort`, so assert on the prompt
# verb, not the word.)
fg_failure_case kiro agent-never-foreground 1
if grep -q '^agent prompt w:p1 /effort' "$TMP/herdr.log"; then
  fail "kiro /effort prompt reached a pane whose agent never foregrounded"
fi
# An unrelated process holding the foreground is not the agent either.
fg_failure_case opus agent-foreground-other 1
# Unreadable answers fail closed at once, like the Devin pre-run check.
fg_failure_case opus agent-foreground-info-fail 1
grep -q 'pane process-info exited 3 before brief injection' <<<"$FG_CASE_OUT" ||
  fail "process-info failure lost its diagnostic: $FG_CASE_OUT"
[[ "$(grep -c '^pane process-info --pane w:p1' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "process-info rc failure must fail on the first check, not be retried"
fg_failure_case opus agent-foreground-garbage 1
grep -q 'pane process-info returned an invalid envelope before brief injection' <<<"$FG_CASE_OUT" ||
  fail "invalid foreground envelope lost its diagnostic: $FG_CASE_OUT"

# The poll is real: a pane that foregrounds the agent two reads late still
# spawns and lands exactly one brief.
: >"$TMP/herdr.log"
fg_late_out="$(TEST_FIXTURE_SCENARIO=agent-late-foreground spawn_base opus 2>&1)" ||
  fail "late-foreground agent must still spawn: $fg_late_out"
grep -q 'landed=yes' <<<"$fg_late_out" ||
  fail "late-foreground agent did not land: $fg_late_out"
[[ "$(grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "late-foreground agent must receive exactly one brief"
[[ "$(grep -c '^pane process-info --pane w:p1' "$TMP/herdr.log")" -eq 3 ]] ||
  fail "late-foreground agent must be admitted on the third process-info read"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "late-foreground pane was closed"; fi
echo "PASS task609 pre-injection foreground-agent check"

# Regression: the kind's herdr --kind name is not always its pane argv0.
# Measured on live panes 2026-09-24 — kimi lands as argv0 "kimi-code", codex
# as a node leader plus a native "codex" child — so the fixture emits those
# real values and every kind below must still be admitted (the #609 follow-up
# hotfix: matching only the kind string fail-closed every real kimi spawn).
for fg_kind_pair in opus:claude codex-terra:codex devin-swe2:devin kimi-k3:kimi grok:grok kiro:kiro oc-glm:opencode agy-flash:agy; do
  fg_model="${fg_kind_pair%%:*}"; fg_kind="${fg_kind_pair##*:}"
  : >"$TMP/herdr.log"
  set +e
  fg_real_out="$(KIMI_CODE_HOME="$TMP/kimi-$fg_model-home" TEST_FIXTURE_SCENARIO=spawn spawn_base "$fg_model" 2>&1)"
  fg_real_rc=$?
  set -e
  [[ "$fg_real_rc" -eq 0 ]] ||
    fail "$fg_model (kind $fg_kind) must spawn under its real argv0 (rc=$fg_real_rc): $fg_real_out"
  grep -q 'landed=yes' <<<"$fg_real_out" ||
    fail "$fg_model (kind $fg_kind) was not admitted under its real argv0: $fg_real_out"
done
echo "PASS foreground check admits every kind under its real argv0"

# Window boundaries on a fake clock: every `date +%s` after the first agent
# start (or, for Devin, the first process-info) reads FAKECLOCK_JUMP seconds
# later. Each retry hands herdr only what is left of the window, and herdr
# refuses a start timeout of 3000ms or less, so Claude's 30s window accepts a
# retry at 26s (4000ms left) and fails closed at 27s, 30s and 31s. Codex's
# 120s window still retries at 31s.
shell_window_case() {
  local model="$1" scenario="$2" after="$3" jump="$4"
  : >"$TMP/herdr.log"
  set +e
  SHELL_WINDOW_OUT="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER="$after" FAKECLOCK_JUMP="$jump" \
    WRK_FIXTURE_SHELL_BUSY_COUNT=1 TEST_FIXTURE_SCENARIO="$scenario" spawn_base "$model" 2>&1)"
  SHELL_WINDOW_RC=$?
  set -e
}
shell_window_case opus shell-busy 'agent start ' 26
[[ "$SHELL_WINDOW_RC" -eq 0 ]] || fail "retry at 26s of 30s must spawn: $SHELL_WINDOW_OUT"
grep -q '^agent start fixture --kind claude --pane w:p1 --timeout 4000 -- ' "$TMP/herdr.log" ||
  fail "retry at 26s must hand herdr only the 4000ms left of the window"
for shell_window_jump in 27 29 30 31; do
  shell_window_case opus shell-busy 'agent start ' "$shell_window_jump"
  [[ "$SHELL_WINDOW_RC" -eq 1 ]] ||
    fail "retry at ${shell_window_jump}s of 30s expected rc=1, got $SHELL_WINDOW_RC: $SHELL_WINDOW_OUT"
  grep -q 'shell not ready within the 30000ms window (agent_pane_busy x1); pane=w:p1' <<<"$SHELL_WINDOW_OUT" ||
    fail "retry at ${shell_window_jump}s lost its window diagnostic: $SHELL_WINDOW_OUT"
  [[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
    fail "retry at ${shell_window_jump}s must not start again past the window"
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "retry at ${shell_window_jump}s leaked its pane"
  if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "retry at ${shell_window_jump}s delivered a brief"; fi
done
# A second ticking over between the window's start reading and the first
# attempt must not shorten a first-attempt success: it keeps the pre-#606
# argv (tester R1 repro: `date +%s` 1000 then 1001 gave --timeout 29000).
mkdir -p "$TMP/tickclock"
cat >"$TMP/tickclock/date" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == +%s ]]; then
  if [[ -e "$FAKECLOCK_STATE" ]]; then echo 1001; else : >"$FAKECLOCK_STATE"; echo 1000; fi
  exit 0
fi
exec /bin/date "$@"
SH
chmod +x "$TMP/tickclock/date"
: >"$TMP/herdr.log"
rm -f "$TMP/tickclock.state"
tick_out="$(PATH="$TMP/tickclock:$PATH" FAKECLOCK_STATE="$TMP/tickclock.state" spawn_base opus 2>&1)" ||
  fail "first-attempt start across a second tick must spawn: $tick_out"
[[ "$(grep -c '^agent start ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "first-attempt start across a second tick must start once"
grep -q '^agent start fixture --kind claude --pane w:p1 --timeout 30000 -- ' "$TMP/herdr.log" ||
  fail "first-attempt start must keep --timeout 30000 across a second tick: $(grep '^agent start ' "$TMP/herdr.log")"
shell_window_case codex-terra shell-busy 'agent start ' 31
[[ "$SHELL_WINDOW_RC" -eq 0 ]] || fail "codex retry at 31s of 120s must spawn: $SHELL_WINDOW_OUT"
grep -q '^agent start fixture --kind codex --pane w:p1 --timeout 89000 -- ' "$TMP/herdr.log" ||
  fail "codex retry at 31s must hand herdr the 89000ms left of its window"

# Devin types through `pane run`, which checks nothing, so wrk polls
# process-info before it until the shell holds the foreground alone. The same
# window then covers detection and the idle wait.
: >"$TMP/herdr.log"
devin_shell_out="$(TEST_FIXTURE_SCENARIO=devin-shell-busy spawn_base devin-swe2 2>&1)" ||
  fail "Devin with a shell ready on the fourth poll must still spawn: $devin_shell_out"
grep -q 'landed=yes' <<<"$devin_shell_out" || fail "late-shell Devin did not land: $devin_shell_out"
devin_shell_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
[[ "$(head -n "$devin_shell_run_no" "$TMP/herdr.log" | grep -c '^pane process-info --pane w:p1$')" -eq 4 ]] ||
  fail "late-shell Devin must poll process-info on the tab-create pane until ready, then pane run"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "late-shell Devin pane was closed"; fi
devin_shell_failure_case() {
  local scenario="$1" diag="$2" out rc
  : >"$TMP/herdr.log"
  set +e
  out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO="$scenario" spawn_base devin-swe2 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 1 ]] || fail "$scenario expected rc=1, got rc=$rc: $out"
  grep -q "Devin pane startup failed: $diag; pane=w:p1" <<<"$out" || fail "$scenario lost its diagnostic: $out"
  if grep -q '^pane run \|^agent rename \|^agent prompt ' "$TMP/herdr.log"; then
    fail "$scenario ran Devin, renamed or delivered into an unready shell"
  fi
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "$scenario leaked its pane"
}
devin_shell_failure_case devin-shell-never-ready 'shell not ready within 30000ms (foreground busy x120)'
devin_shell_failure_case devin-process-info-fail 'pane process-info exited 3 before pane run'
[[ "$(grep -c '^pane process-info ' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "a failed process-info must not be polled again (one check + one diagnostic)"
devin_shell_failure_case devin-process-info-garbage 'pane process-info returned an invalid envelope before pane run'
[[ "$(grep -c '^pane process-info ' "$TMP/herdr.log")" -eq 2 ]] ||
  fail "an unreadable process-info must not be polled again (one check + one diagnostic)"
shell_window_case devin-swe2 devin-shell-busy 'pane process-info ' 29
[[ "$SHELL_WINDOW_RC" -eq 0 ]] || fail "Devin shell ready at 29s of 30s must spawn: $SHELL_WINDOW_OUT"
grep -qx 'agent wait w:p1 --until idle --timeout 1000' "$TMP/herdr.log" ||
  fail "Devin shell ready at 29s must leave the idle wait only the 1000ms left"
for shell_window_jump in 30 31; do
  shell_window_case devin-swe2 devin-shell-busy 'pane process-info ' "$shell_window_jump"
  [[ "$SHELL_WINDOW_RC" -eq 1 ]] ||
    fail "Devin shell at ${shell_window_jump}s expected rc=1, got $SHELL_WINDOW_RC: $SHELL_WINDOW_OUT"
  grep -q 'shell not ready within 30000ms (foreground busy x1)' <<<"$SHELL_WINDOW_OUT" ||
    fail "Devin shell at ${shell_window_jump}s lost its window diagnostic: $SHELL_WINDOW_OUT"
  if grep -q '^pane run ' "$TMP/herdr.log"; then fail "Devin shell at ${shell_window_jump}s ran past the window"; fi
  grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "Devin shell at ${shell_window_jump}s leaked its pane"
done
echo "PASS task606 shell-ready wait: agent_pane_busy retry, Devin process-info poll, window bound, fail-closed"

# #604/m1b (hk:doc evidence/2026-09-24/task604-m1b-repro): the m1b herdr 0.9.0
# process-info reply has no "result" wrapper and no foreground_process_group_id
# but still names shell_pid and the foreground list. While the foreground is
# an rc-file subprocess (compinit's grep) the answer is "not ready yet" and
# must be polled inside the window — the observed m1b failure was this
# readable reply being classified as an invalid envelope after one check.
# Mutant: removing the wait types the devin argv into the busy shell (pane run
# fires on poll 1), and strict-parsing the envelope fails the spawn outright.
: >"$TMP/herdr.log"
devin_m1b_out="$(TEST_FIXTURE_SCENARIO=devin-shell-busy-m1b spawn_base devin-swe2 2>&1)" ||
  fail "m1b-shape shell ready on the fourth poll must still spawn: $devin_m1b_out"
grep -q 'landed=yes' <<<"$devin_m1b_out" ||
  fail "m1b-shape late-shell Devin did not land: $devin_m1b_out"
devin_m1b_run_no="$(grep -n '^pane run w:p1 devin ' "$TMP/herdr.log" | cut -d: -f1)"
[[ "$(head -n "$devin_m1b_run_no" "$TMP/herdr.log" | grep -c '^pane process-info --pane w:p1$')" -eq 4 ]] ||
  fail "m1b-shape Devin must poll process-info until the shell is alone in the foreground"
if grep -q '^pane close ' "$TMP/herdr.log"; then fail "m1b-shape late-shell Devin pane was closed"; fi
devin_shell_failure_case devin-shell-never-ready-m1b 'shell not ready within 30000ms (foreground busy x120)'
echo "PASS 604-m1b-envelope: unwrapped process-info polls shell-busy foreground, fail-closed at window"

# #979 (Pi incident, jobs/971-stale-race-20260929-1848): a fresh pane can hold
# the shell alone in the foreground while zsh sits in a pending rc-file read
# — omz's update check holds `read -k 1`, which ate the `d` of the typed
# `devin` and left `evin` to run. process-info cannot see it, so after the
# foreground check passes wrk types a space-prefixed printf probe carrying a
# fresh token and requires the token back as its own output line before the
# agent argv is typed; ANY token this spawn typed counts, because lines
# queued behind a still-sourcing rc all execute when the prompt arrives and
# a `read -k 1` that ate the leading space still runs the remainder. An
# unanswered probe is only ever RETYPED — never interrupted: fix-round-1
# showed ctrl+c during rc sourcing SIGINTs the rest of the rc and leaves the
# agent in a truncated environment. The only `herdr pane run` call site that
# types into a fresh shell pane is devin_start_in_pane (every other kind's
# start goes through `agent start`, which herdr gates internally), so the
# probe lives there and these cases cover it.
t979_xdg="$TMP/t979-xdg"
devin_trust_seed_store "$t979_xdg" "$ROOT" "$(cd "$ROOT" && pwd -P)"

# AC3: an ordinary ready shell — exactly one probe line and one agent command
# typed, the probe's token answered on the first pane read, spawn rc 0.
: >"$TMP/herdr-t979-normal.log"; rm -f "$TMP/herdr-t979-normal.log.executed"
devin_normal_out="$(TEST_FIXTURE_SCENARIO=devin-idle devin_spawn_at "$t979_xdg" "$ROOT" t979-normal "$(mint_task)" 2>&1)" ||
  fail "ready-shell devin spawn failed: $devin_normal_out"
grep -q 'landed=yes' <<<"$devin_normal_out" || fail "ready-shell devin did not land: $devin_normal_out"
t979_log="$TMP/herdr-t979-normal.log"
[[ "$(grep -c '^pane run ' "$t979_log")" -eq 2 ]] ||
  fail "ready shell must see exactly one probe and one agent run: $(grep '^pane run ' "$t979_log")"
grep -qE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-[0-9-]+'" "$t979_log" ||
  fail "probe line missing or not space-prefixed printf: $(grep '^pane run ' "$t979_log")"
[[ "$(grep -c '^pane read w:p1 ' "$t979_log")" -eq 1 ]] ||
  fail "answered probe must cost exactly one pane read (one poll): $(grep -c '^pane read ' "$t979_log")"
t979_probe_no="$(grep -nE "^pane run w:p1 +printf" "$t979_log" | cut -d: -f1)"
t979_read_no="$(grep -n '^pane read w:p1 ' "$t979_log" | cut -d: -f1)"
t979_agent_no="$(grep -n '^pane run w:p1 devin ' "$t979_log" | cut -d: -f1)"
(( t979_probe_no < t979_read_no && t979_read_no < t979_agent_no )) ||
  fail "probe must be typed, its output read, and only then the agent command"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
echo "PASS 979-AC3 ready shell: one probe, one read, one agent run"

# The Pi shape exactly: `read -k 1` eats the first CHARACTER (the probe's
# leading space) and the remainder `printf …` still runs — the probe passes
# on the first try with no retype and no interrupt.
: >"$TMP/herdr-t979-key.log"; rm -f "$TMP/herdr-t979-key.log.executed"
devin_key_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-key devin_spawn_at "$t979_xdg" "$ROOT" t979-key "$(mint_task)" 2>&1)" ||
  fail "Devin behind a pending read -k 1 must still spawn: $devin_key_out"
grep -q 'landed=yes' <<<"$devin_key_out" || fail "read -k 1 devin did not land: $devin_key_out"
t979_log="$TMP/herdr-t979-key.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -eq 1 ]] ||
  fail "a read -k 1-eaten probe must still execute its remainder: $(grep '^pane run ' "$t979_log")"
[[ "$(grep -c '^pane run w:p1 devin ' "$t979_log")" -eq 1 ]] ||
  fail "devin argv must be typed exactly once, after the shell proved it runs lines"
grep -qx 'devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' \
  "$t979_log.executed" ||
  fail "the fake shell must execute the full devin argv: $(cat "$t979_log.executed")"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
echo "PASS 979 eaten first char (read -k 1): probe remainder ran, no retype"

# AC1: a pending full-line read consumes the first typed line — the probe
# goes unanswered, it is retyped with a new token (retype only, never an
# interrupt), and the full devin argv then lands unharmed.
: >"$TMP/herdr-t979-eaten.log"; rm -f "$TMP/herdr-t979-eaten.log.executed"
devin_eaten_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-line devin_spawn_at "$t979_xdg" "$ROOT" t979-eaten "$(mint_task)" 2>&1)" ||
  fail "Devin behind a pending read must still spawn: $devin_eaten_out"
grep -q 'landed=yes' <<<"$devin_eaten_out" || fail "eaten-line devin did not land: $devin_eaten_out"
t979_log="$TMP/herdr-t979-eaten.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -eq 2 ]] ||
  fail "unanswered probe must be retyped with a fresh token: $(grep '^pane run ' "$t979_log")"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
[[ "$(grep -c '^pane run w:p1 devin ' "$t979_log")" -eq 1 ]] ||
  fail "devin argv must be typed exactly once, after the shell proved it runs lines"
grep -qx 'devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' \
  "$t979_log.executed" ||
  fail "the fake shell must execute the full devin argv: $(cat "$t979_log.executed")"
[[ "$(grep -c 'wrk-ready-' "$t979_log.executed")" -eq 1 ]] ||
  fail "the retried probe — and not the eaten one — must be the only executed probe"
grep -qx 'env=full' "$t979_log.devenv" ||
  fail "devin must inherit the fully-sourced rc environment: $(cat "$t979_log.devenv" 2>/dev/null)"
echo "PASS 979-AC1 eaten first line: probe retried, agent argv intact, rc 0"

# The fix-round-1 hazard: rc still sourcing while probes are typed. Lines
# queue and ALL execute when rc finishes — the answer to an earlier probe is
# proof, the spawn lands with the full environment, and no ctrl+c is sent.
: >"$TMP/herdr-t979-slowrc.log"; rm -f "$TMP/herdr-t979-slowrc.log.executed" "$TMP/herdr-t979-slowrc.log.devenv"
devin_slowrc_out="$(TEST_FIXTURE_SCENARIO=devin-slow-rc devin_spawn_at "$t979_xdg" "$ROOT" t979-slowrc "$(mint_task)" 2>&1)" ||
  fail "Devin behind a slow rc file must still spawn: $devin_slowrc_out"
grep -q 'landed=yes' <<<"$devin_slowrc_out" || fail "slow-rc devin did not land: $devin_slowrc_out"
t979_log="$TMP/herdr-t979-slowrc.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -gt 1 ]] ||
  fail "an unanswered probe behind a slow rc must be retyped inside the window: $(grep '^pane run ' "$t979_log")"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
grep -qx 'env=full' "$t979_log.devenv" ||
  fail "devin must inherit the fully-sourced rc environment, not a ctrl+c-truncated one: $(cat "$t979_log.devenv" 2>/dev/null)"
grep -qx 'devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' \
  "$t979_log.executed" ||
  fail "the fake shell must execute the full devin argv: $(cat "$t979_log.executed")"
echo "PASS 979 slow rc: queued probes answered late, full env, no interrupt"

# AC2: a pending read that never ends — the probe is never answered, the
# spawn fails inside START_TIMEOUT with its own reason, the pane is cleaned
# up as today, and the agent command is never typed.
: >"$TMP/herdr-t979-stuck.log"
set +e
devin_stuck_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=devin-read-never-ends devin_spawn_at "$t979_xdg" "$ROOT" t979-stuck "$(mint_task)" 2>&1)"
devin_stuck_rc=$?
set -e
[[ "$devin_stuck_rc" -eq 1 ]] || fail "never-answering probe expected rc=1, got $devin_stuck_rc: $devin_stuck_out"
grep -q 'Devin pane startup failed: shell did not execute a readiness probe within 30000ms' <<<"$devin_stuck_out" ||
  fail "never-answering probe lost its distinct diagnostic: $devin_stuck_out"
t979_log="$TMP/herdr-t979-stuck.log"
[[ "$(grep -cE "^pane run w:p1 +printf '%s\\\\n' 'wrk-ready-" "$t979_log")" -gt 1 ]] ||
  fail "an unanswered probe must be retyped inside the window"
if grep -q '^pane send-keys ' "$t979_log"; then
  fail "wrk must never interrupt a shell that may still be sourcing its rc file: $(grep '^pane send-keys ' "$t979_log")"
fi
if grep -q '^pane run w:p1 devin ' "$t979_log"; then
  fail "agent command was typed into a shell that never executed a probe"
fi
grep -qx 'pane close w:p1' "$t979_log" || fail "never-answering probe leaked its pane"
if grep -q '^agent prompt ' "$t979_log"; then fail "never-answering probe delivered a brief"; fi
grep -q 'Devin spawn failure artifacts preserved under ' <<<"$devin_stuck_out" ||
  fail "never-answering probe must keep the existing diagnostics path: $devin_stuck_out"
echo "PASS 979-AC2 probe never answered: distinct reason, pane closed, no agent run"

# No devin scenario may ever send pane keys — a ctrl+c into a still-sourcing
# rc truncates the environment the agent then inherits.
for t979_log in "$TMP"/herdr*.log; do
  if grep -q '^pane send-keys ' "$t979_log" 2>/dev/null; then
    fail "pane send-keys reached a devin pane in $t979_log: $(grep '^pane send-keys ' "$t979_log")"
  fi
done

# AC6 mutants — assertion-RED invariants:
#   M1 "the agent command is typed only after the shell has executed a probe"
#      (mutant: ready foreground returns immediately, skipping the probe)
#   M2 "a probe line that echoed but did not run is not proof"
#      (mutant: substring match accepts the echoed command line)
#   M3 "wrk never interrupts a shell that may still be sourcing its rc file"
#      (mutant: ctrl+c after the miss count, then retype)
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t979-no-probe \
  'if [[ "$ready" == yes ]]; then devin_probe_send || return 1; fi' \
  'if [[ "$ready" == yes ]]; then return 0; fi'
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t979-echo-match \
  'grep -qxF "$probe_any"' \
  'grep -qF "$probe_any"'
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
devin_trust_mutant t979-ctrl-c \
  '(( probe_misses >= DEVIN_PROBE_MISS_POLLS )) && probe_token=""' \
  '(( probe_misses >= DEVIN_PROBE_MISS_POLLS )) && { "$HERDR" pane send-keys "$PANE" ctrl+c >/dev/null 2>&1 || true; probe_token=""; }'
set +e
t979_m1_out="$(TEST_FIXTURE_SCENARIO=devin-read-eats-line WRK_UNDER_TEST="$TMP/mut-wrk-t979-no-probe" \
  devin_spawn_at "$t979_xdg" "$ROOT" t979-m1 "$(mint_task)" 2>&1)"
t979_m1_rc=$?
t979_m2_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 \
  TEST_FIXTURE_SCENARIO=devin-read-never-ends WRK_UNDER_TEST="$TMP/mut-wrk-t979-echo-match" \
  devin_spawn_at "$t979_xdg" "$ROOT" t979-m2 "$(mint_task)" 2>&1)"
t979_m2_rc=$?
rm -f "$TMP/herdr-t979-m3.log.devenv"
t979_m3_out="$(TEST_FIXTURE_SCENARIO=devin-slow-rc WRK_UNDER_TEST="$TMP/mut-wrk-t979-ctrl-c" \
  devin_spawn_at "$t979_xdg" "$ROOT" t979-m3 "$(mint_task)" 2>&1)"
t979_m3_rc=$?
set -e
# M1 under AC1's eaten-line pane: the devin argv itself is consumed, so the
# spawn must NOT reach the OK line (real run expects rc 0 + landed=yes).
[[ "$t979_m1_rc" -ne 0 ]] ||
  fail "M1 (probe skipped): spawn succeeded despite the eaten agent line: $t979_m1_out"
if grep -q '^OK ' <<<"$t979_m1_out"; then
  fail "M1 (probe skipped): OK line printed for an eaten agent command: $t979_m1_out"
fi
# M2 under AC2's never-ending read: the echoed probe is accepted as proof, so
# the agent command gets typed into the dead shell — the spawn must fail, and
# NOT with the never-answered reason the real check produces.
[[ "$t979_m2_rc" -ne 0 ]] ||
  fail "M2 (echo accepted): spawn succeeded on a pane that only echoes: $t979_m2_out"
if grep -q 'shell did not execute a readiness probe' <<<"$t979_m2_out"; then
  fail "M2 (echo accepted) lost the divergence: substring match must pass the echo and fail downstream"
fi
grep -q '^pane run w:p1 devin ' "$TMP/herdr-t979-m2.log" ||
  fail "M2 (echo accepted) proof — the agent command must have been (wrongly) typed"
# M3 under the slow-rc pane: the ctrl+c ends rc early — the spawn still lands
# (queued probes run), but the devin argv executes in a truncated
# environment. The real assertion it breaks is the slow-rc case's env=full.
[[ "$t979_m3_rc" -eq 0 ]] ||
  fail "M3 (ctrl+c sent): spawn was expected to land truncated, not fail: $t979_m3_out"
grep -qx 'env=truncated' "$TMP/herdr-t979-m3.log.devenv" ||
  fail "M3 (ctrl+c sent) must truncate the rc environment devin inherits: $(cat "$TMP/herdr-t979-m3.log.devenv" 2>/dev/null)"
grep -q '^pane send-keys w:p1 ctrl+c' "$TMP/herdr-t979-m3.log" ||
  fail "M3 (ctrl+c sent) proof — the interrupt must appear in the herdr log"
echo "PASS 979-AC6 mutants red: M1 skip-probe, M2 echo-as-proof, M3 ctrl+c"

expect_exit 2 spawn_base devin-swe2 --effort high
# Task 240 pilot (operator decision 2026-09-14 §3): the devin-swe2 worker
# spelling is now admitted under --role builder too — this acceptance replaces
# the pre-pilot `expect_exit 2` refusal that pinned devin as worker-only.
set +e
devin_builder_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 --role builder --lane devin-builder-lane --parent parent-lane --job devin-worker-builder-job 2>&1)"
devin_builder_rc=$?
set -e
[[ "$devin_builder_rc" -eq 0 ]] ||
  fail "devin-swe2 must be admitted under --role builder (rc=$devin_builder_rc): $devin_builder_out"
grep -q 'model=devin-swe2' <<<"$devin_builder_out" ||
  fail "devin-swe2 builder spawn output lost its model: $devin_builder_out"
grep -q '^OK ' <<<"$devin_builder_out" ||
  fail "devin-swe2 builder spawn did not reach the OK line: $devin_builder_out"
echo "PASS devin-swe2 worker kind/argv/no-effort snapshot + builder-pilot admission"

# Task 281 (operator decision 2026-09-14 devin-pro-paid-models): the three
# additional Devin model profiles reuse the identical unattended argv — only
# the --model name differs — and reject --effort like devin-swe2. #635 adds
# the effort rungs as named profiles (effort lives inside the model id), same
# argv skeleton and same --effort rejection.
for devin_pair in "devin-glm52:glm-5-2" "devin-swe17:swe-1-7" "devin-ds41:deepseek-v4-1-flash-high" \
  "devin-swe2-medium:swe-2-medium" "devin-swe2-max:swe-2-max" "devin-ds41-max:deepseek-v4-1-flash-max"; do
  devin_profile="${devin_pair%%:*}"
  devin_model="${devin_pair#*:}"
  : >"$TMP/herdr.log"
  devin_variant_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base "$devin_profile" 2>&1)"
  grep -q "model=$devin_profile" <<<"$devin_variant_out" ||
    fail "$devin_profile spawn output lost its model: $devin_variant_out"
  grep -q 'status=idle' <<<"$devin_variant_out" ||
    fail "$devin_profile did not reach idle landing: $devin_variant_out"
  devin_variant_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
  [[ "$devin_variant_run" == "pane run w:p1 devin --model $devin_model --permission-mode dangerous --respect-workspace-trust false" ]] ||
    fail "$devin_profile run argv snapshot mismatch: $devin_variant_run"
  [[ " $devin_variant_run " != *' --effort '* ]] ||
    fail "$devin_profile run argv must not contain effort"
  expect_exit 2 spawn_base "$devin_profile" --effort high
done
echo "PASS devin-glm52/devin-swe17/devin-ds41 + #635 effort-variant worker kind/argv/no-effort snapshots"

# #635 AC2: an unknown effort token is still refused on the new spellings —
# the generic unknown-effort die fires before the devin no-effort guard.
expect_exit 2 spawn_base devin-swe2-max --effort bogus
expect_exit 2 spawn_base devin-ds41-max --effort medium

# -- #912: devin trusted-workspaces seeding ----------------------------------
# Helpers (devin_spawn_at / devin_trust_seed_store / devin_trust_paths /
# devin_trust_mutant) live with spawn_base above so earlier sections can seed
# their own fixture XDG stores.

# AC1: an uncovered spawn cwd is appended — resolved to its physical path —
# alongside the pre-existing entry, and a dated backup is written first.
mkdir -p "$TMP/t912-add/deep/nest" "$TMP/t912-elsewhere"
t912_xdg="$TMP/t912-xdg-add"
devin_trust_seed_store "$t912_xdg" "$TMP/t912-elsewhere"
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-add/deep/nest" devin912a "$(mint_task)" 2>&1)" ||
  fail "devin spawn over an uncovered cwd failed: $t912_out"
grep -q '^OK ' <<<"$t912_out" || fail "devin trust-seed spawn lost its OK line: $t912_out"
t912_resolved="$(cd "$TMP/t912-add/deep/nest" && pwd -P)"
devin_trust_paths "$t912_xdg" | grep -qx "$t912_resolved" ||
  fail "resolved spawn cwd was not added: $(devin_trust_paths "$t912_xdg")"
[[ "$(devin_trust_paths "$t912_xdg" | wc -l | tr -d ' ')" -eq 2 ]] ||
  fail "store gained more than the spawn cwd: $(devin_trust_paths "$t912_xdg")"
devin_trust_paths "$t912_xdg" | grep -qx "$TMP/t912-elsewhere" ||
  fail "pre-existing entry was removed: $(devin_trust_paths "$t912_xdg")"
compgen -G "$t912_xdg/devin/cli/trusted_workspaces.json.bak-*" >/dev/null ||
  fail "trust write produced no backup"
echo "PASS 912-devin-trust adds only the resolved spawn cwd"

# AC1: an already-trusted cwd is a pure no-op — bytes and backup dir unchanged.
mkdir -p "$TMP/t912-same"
t912_xdg="$TMP/t912-xdg-same"
devin_trust_seed_store "$t912_xdg" "$(cd "$TMP/t912-same" && pwd -P)"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-same.before"
devin_spawn_at "$t912_xdg" "$TMP/t912-same" devin912b "$(mint_task)" >/dev/null ||
  fail "devin spawn over an already-trusted cwd failed"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-same.before" ||
  fail "already-trusted cwd rewrote the store"
if compgen -G "$t912_xdg/devin/cli/trusted_workspaces.json.bak-*" >/dev/null; then
  fail "no-op trust check produced a backup"
fi
echo "PASS 912-devin-trust already-trusted is a pure no-op"

# AC1: a parent-covered cwd is also a pure no-op — inherited trust counts, the
# child path is never appended, and the parent is what stays trusted.
mkdir -p "$TMP/t912-parent/child"
t912_xdg="$TMP/t912-xdg-parent"
devin_trust_seed_store "$t912_xdg" "$(cd "$TMP/t912-parent" && pwd -P)"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-parent.before"
devin_spawn_at "$t912_xdg" "$TMP/t912-parent/child" devin912c "$(mint_task)" >/dev/null ||
  fail "devin spawn over a parent-covered cwd failed"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-parent.before" ||
  fail "parent-covered cwd rewrote the store"
devin_trust_paths "$t912_xdg" | grep -qx "$(cd "$TMP/t912-parent/child" && pwd -P)" &&
  fail "parent-covered cwd appended the child path"
echo "PASS 912-devin-trust parent-covered is a pure no-op"

# AC1: a trusted *sibling* does not cover the target — only ancestors do.
mkdir -p "$TMP/t912-sib/trusted" "$TMP/t912-sib/untrusted"
t912_xdg="$TMP/t912-xdg-sib"
devin_trust_seed_store "$t912_xdg" "$(cd "$TMP/t912-sib/trusted" && pwd -P)"
devin_spawn_at "$t912_xdg" "$TMP/t912-sib/untrusted" devin912sib "$(mint_task)" >/dev/null ||
  fail "devin spawn next to a trusted sibling failed"
devin_trust_paths "$t912_xdg" | grep -qx "$(cd "$TMP/t912-sib/untrusted" && pwd -P)" ||
  fail "trusted sibling wrongly covered the spawn cwd"
echo "PASS 912-devin-trust sibling trust does not cover"

# AC2: a corrupt store is refused before any pane — bytes preserved verbatim.
mkdir -p "$TMP/t912-cwd-corrupt"
t912_xdg="$TMP/t912-xdg-corrupt"
mkdir -p "$t912_xdg/devin/cli"
printf '{ not json\n' >"$t912_xdg/devin/cli/trusted_workspaces.json"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-corrupt.before"
set +e
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-cwd-corrupt" devin912d "$(mint_task)" 2>&1)"
t912_rc=$?
set -e
[[ "$t912_rc" -ne 0 ]] || fail "corrupt devin trust store did not refuse the spawn"
grep -q 'not valid JSON' <<<"$t912_out" ||
  fail "corrupt refusal lost its diagnostic: $t912_out"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-corrupt.before" ||
  fail "corrupt store was overwritten"
[[ ! -e "$TMP/herdr-devin912d.log" ]] ||
  fail "corrupt-store refusal still reached herdr"
echo "PASS 912-devin-trust corrupt store refused, bytes preserved"

# AC2: an unparsable *shape* (trusted_paths not a string list) is refused the
# same way — valid JSON alone must not be enough to write.
mkdir -p "$TMP/t912-cwd-shape"
t912_xdg="$TMP/t912-xdg-shape"
mkdir -p "$t912_xdg/devin/cli"
printf '{"trusted_paths": "yes"}\n' >"$t912_xdg/devin/cli/trusted_workspaces.json"
cp "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-shape.before"
set +e
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-cwd-shape" devin912sh "$(mint_task)" 2>&1)"
t912_rc=$?
set -e
[[ "$t912_rc" -ne 0 ]] || fail "malformed trusted_paths did not refuse the spawn"
grep -q 'trusted_paths' <<<"$t912_out" ||
  fail "shape refusal lost its diagnostic: $t912_out"
cmp -s "$t912_xdg/devin/cli/trusted_workspaces.json" "$TMP/t912-shape.before" ||
  fail "malformed store was overwritten"
echo "PASS 912-devin-trust malformed shape refused, bytes preserved"

# AC2: a missing store is refused closed — nothing is created, no pane runs.
mkdir -p "$TMP/t912-cwd-missing"
t912_xdg="$TMP/t912-xdg-missing"
mkdir -p "$t912_xdg/devin/cli"
set +e
t912_out="$(devin_spawn_at "$t912_xdg" "$TMP/t912-cwd-missing" devin912e "$(mint_task)" 2>&1)"
t912_rc=$?
set -e
[[ "$t912_rc" -ne 0 ]] || fail "missing devin trust store did not refuse the spawn"
grep -q 'store missing' <<<"$t912_out" ||
  fail "missing-store refusal lost its diagnostic: $t912_out"
[[ ! -e "$t912_xdg/devin/cli/trusted_workspaces.json" ]] ||
  fail "missing store was created by the spawn"
[[ ! -e "$TMP/herdr-devin912e.log" ]] ||
  fail "missing-store refusal still reached herdr"
echo "PASS 912-devin-trust missing store refused, nothing created"

# AC1/AC3: two concurrent spawns into the same store — both entries must land
# and the pre-existing entry must survive. The test delay holds each writer's
# read->write gap open so a lost update would be deterministic, not luck.
devin_trust_seed_store "$TMP/t912-xdg-race" "$TMP/t912-race-origin"
mkdir -p "$TMP/t912-race-a" "$TMP/t912-race-b" "$TMP/t912-race-origin"
t912_ta="$(mint_task)" t912_tb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.5 \
  devin_spawn_at "$TMP/t912-xdg-race" "$TMP/t912-race-a" devin912fa "$t912_ta" \
  >"$TMP/t912-race-a.out" 2>&1 &
t912_pa=$!
WRK_TEST_TRUST_DELAY_S=0.5 \
  devin_spawn_at "$TMP/t912-xdg-race" "$TMP/t912-race-b" devin912fb "$t912_tb" \
  >"$TMP/t912-race-b.out" 2>&1 &
t912_pb=$!
set +e
wait "$t912_pa"; t912_ra=$?
wait "$t912_pb"; t912_rb=$?
set -e
[[ "$t912_ra" -eq 0 && "$t912_rb" -eq 0 ]] ||
  fail "concurrent devin spawns failed rc=$t912_ra/$t912_rb: $(cat "$TMP/t912-race-a.out" "$TMP/t912-race-b.out")"
t912_ra_path="$(cd "$TMP/t912-race-a" && pwd -P)"
t912_rb_path="$(cd "$TMP/t912-race-b" && pwd -P)"
devin_trust_paths "$TMP/t912-xdg-race" | grep -qx "$t912_ra_path" ||
  fail "concurrent spawn lost entry A: $(devin_trust_paths "$TMP/t912-xdg-race")"
devin_trust_paths "$TMP/t912-xdg-race" | grep -qx "$t912_rb_path" ||
  fail "concurrent spawn lost entry B: $(devin_trust_paths "$TMP/t912-xdg-race")"
devin_trust_paths "$TMP/t912-xdg-race" | grep -qx "$TMP/t912-race-origin" ||
  fail "concurrent spawn removed the pre-existing entry"
[[ "$(devin_trust_paths "$TMP/t912-xdg-race" | wc -l | tr -d ' ')" -eq 3 ]] ||
  fail "concurrent spawn produced wrong entry count"
echo "PASS 912-devin-trust concurrent spawns keep both entries"

# AC3: with XDG_DATA_HOME unset the store resolves under the fixture HOME —
# the real HOME store is never consulted.
t912_home="$TMP/t912-home"
mkdir -p "$t912_home/.local/share/devin/cli" "$TMP/t912-cwd-home"
printf '{"trusted_paths": []}\n' >"$t912_home/.local/share/devin/cli/trusted_workspaces.json"
t912_home_out="$(env -u XDG_DATA_HOME HOME="$t912_home" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=devin-idle WRK_FIXTURE_LOG="$TMP/herdr-devin912h.log" \
  WRK_FIXTURE_MARKER="" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel-devin912h.log" \
  WRK_REFRESH_LOG="$TMP/refresh-devin912h.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-devin912h.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t912-cwd-home" -m devin-swe2 -p "$PROMPT" -w w \
  -l devin912h --t T1 --task "$(mint_task)" 2>&1)" ||
  fail "HOME-fallback devin spawn failed: $t912_home_out"
devin_trust_paths "$t912_home/.local/share" |
  grep -qx "$(cd "$TMP/t912-cwd-home" && pwd -P)" ||
  fail "HOME-fallback store did not gain the spawn cwd"
echo "PASS 912-devin-trust XDG unset falls back to fixture HOME"

# -- assertion-RED mutants -------------------------------------------------
# Each mutant weakens exactly one rule; each run must produce the bad outcome
# the corresponding assertion above rejects, proving the assertion is live.
# 1) widening: store the parent instead of the cwd.
mkdir -p "$TMP/t912-m1/deep/nest"
devin_trust_seed_store "$TMP/t912-xdg-m1" "$TMP/t912-m1-else"
devin_trust_mutant widen \
  'data["trusted_paths"] = paths + [cwd]' \
  'data["trusted_paths"] = paths + [os.path.dirname(cwd)]'
WRK_UNDER_TEST="$TMP/mut-wrk-widen" \
  devin_spawn_at "$TMP/t912-xdg-m1" "$TMP/t912-m1/deep/nest" devin912m1 "$(mint_task)" \
  >/dev/null 2>&1 || true
if devin_trust_paths "$TMP/t912-xdg-m1" | grep -qx "$(cd "$TMP/t912-m1/deep/nest" && pwd -P)"; then
  fail "parent-widening mutant survived: the spawn cwd was still added"
fi
devin_trust_paths "$TMP/t912-xdg-m1" |
  grep -qx "$(cd "$TMP/t912-m1/deep" && pwd -P)" ||
  fail "parent-widening mutant did not apply (parent entry absent)"
echo "PASS 912-devin-trust mutant: parent widening goes RED"

# 2) coverage degraded to equality: a parent-covered cwd gets appended.
mkdir -p "$TMP/t912-m2/parent/child"
devin_trust_seed_store "$TMP/t912-xdg-m2" "$(cd "$TMP/t912-m2/parent" && pwd -P)"
cp "$TMP/t912-xdg-m2/devin/cli/trusted_workspaces.json" "$TMP/t912-m2.before"
devin_trust_mutant eqcover \
  'if os.path.commonpath((base, target)) == base:' \
  'if base == target:'
WRK_UNDER_TEST="$TMP/mut-wrk-eqcover" \
  devin_spawn_at "$TMP/t912-xdg-m2" "$TMP/t912-m2/parent/child" devin912m2 "$(mint_task)" \
  >/dev/null 2>&1 || true
cmp -s "$TMP/t912-xdg-m2/devin/cli/trusted_workspaces.json" "$TMP/t912-m2.before" &&
  fail "ancestor-coverage mutant survived: parent-covered cwd left the store untouched"
echo "PASS 912-devin-trust mutant: equality-only coverage goes RED"

# 3) coverage skipped entirely: an already-trusted cwd gets appended again.
mkdir -p "$TMP/t912-m3"
devin_trust_seed_store "$TMP/t912-xdg-m3" "$(cd "$TMP/t912-m3" && pwd -P)"
cp "$TMP/t912-xdg-m3/devin/cli/trusted_workspaces.json" "$TMP/t912-m3.before"
devin_trust_mutant always 'if covered():' 'if False:'
WRK_UNDER_TEST="$TMP/mut-wrk-always" \
  devin_spawn_at "$TMP/t912-xdg-m3" "$TMP/t912-m3" devin912m3 "$(mint_task)" \
  >/dev/null 2>&1 || true
cmp -s "$TMP/t912-xdg-m3/devin/cli/trusted_workspaces.json" "$TMP/t912-m3.before" &&
  fail "coverage-skip mutant survived: already-trusted cwd left the store untouched"
echo "PASS 912-devin-trust mutant: skipped coverage check goes RED"

# 4) corrupt tolerated: invalid JSON silently replaced by an empty store.
mkdir -p "$TMP/t912-m4-cwd" "$TMP/t912-xdg-m4/devin/cli"
printf '{ not json\n' >"$TMP/t912-xdg-m4/devin/cli/trusted_workspaces.json"
cp "$TMP/t912-xdg-m4/devin/cli/trusted_workspaces.json" "$TMP/t912-m4.before"
devin_trust_mutant corrupt-ok \
  'refuse("store is not valid JSON: %s (%s) — refusing to overwrite a corrupt file" % (path, exc))' \
  'data = {"trusted_paths": []}'
WRK_UNDER_TEST="$TMP/mut-wrk-corrupt-ok" \
  devin_spawn_at "$TMP/t912-xdg-m4" "$TMP/t912-m4-cwd" devin912m4 "$(mint_task)" \
  >/dev/null 2>&1 || true
cmp -s "$TMP/t912-xdg-m4/devin/cli/trusted_workspaces.json" "$TMP/t912-m4.before" &&
  fail "corrupt-tolerant mutant survived: corrupt store was never rewritten"
echo "PASS 912-devin-trust mutant: corrupt tolerated goes RED"

# 5) entries dropped: append becomes replace.
mkdir -p "$TMP/t912-m5-cwd" "$TMP/t912-m5-keep"
devin_trust_seed_store "$TMP/t912-xdg-m5" "$TMP/t912-m5-keep"
devin_trust_mutant drop \
  'data["trusted_paths"] = paths + [cwd]' \
  'data["trusted_paths"] = [cwd]'
WRK_UNDER_TEST="$TMP/mut-wrk-drop" \
  devin_spawn_at "$TMP/t912-xdg-m5" "$TMP/t912-m5-cwd" devin912m5 "$(mint_task)" \
  >/dev/null 2>&1 || true
if devin_trust_paths "$TMP/t912-xdg-m5" | grep -qx "$TMP/t912-m5-keep"; then
  fail "entry-dropping mutant survived: pre-existing entry still present"
fi
echo "PASS 912-devin-trust mutant: dropped entries go RED"

# 6) missing store silently created instead of refused.
mkdir -p "$TMP/t912-m6-cwd" "$TMP/t912-xdg-m6/devin/cli"
devin_trust_mutant missing-create \
  'refuse("store missing: %s — trust a directory in devin once or restore the file; not creating it" % path)' \
  'open(path, "w").write('"'"'{"trusted_paths": []}'"'"')'
WRK_UNDER_TEST="$TMP/mut-wrk-missing-create" \
  devin_spawn_at "$TMP/t912-xdg-m6" "$TMP/t912-m6-cwd" devin912m6 "$(mint_task)" \
  >/dev/null 2>&1 || true
[[ -e "$TMP/t912-xdg-m6/devin/cli/trusted_workspaces.json" ]] ||
  fail "missing-store-creating mutant survived: store still absent"
echo "PASS 912-devin-trust mutant: missing store created goes RED"

# 7) lock dropped: with the read->write gap held open, two writers lose one
# entry — the concurrency assertions above must fail against this mutant.
devin_trust_seed_store "$TMP/t912-xdg-m7" "$TMP/t912-m7-origin"
mkdir -p "$TMP/t912-m7-a" "$TMP/t912-m7-b" "$TMP/t912-m7-origin"
# The flock line also exists verbatim in #951's claude block — anchor on the
# devin-only `try:\n        try:` that follows it.
devin_trust_mutant nolock \
  '    fcntl.flock(lock_fd, fcntl.LOCK_EX)
    try:
        try:' \
  '    pass  # mutant: no flock
    try:
        try:'
t912_ma="$(mint_task)" t912_mb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  devin_spawn_at "$TMP/t912-xdg-m7" "$TMP/t912-m7-a" devin912ma "$t912_ma" \
  >/dev/null 2>&1 &
t912_pa=$!
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  devin_spawn_at "$TMP/t912-xdg-m7" "$TMP/t912-m7-b" devin912mb "$t912_mb" \
  >/dev/null 2>&1 &
t912_pb=$!
wait "$t912_pa" "$t912_pb" || true
t912_m7_count="$(devin_trust_paths "$TMP/t912-xdg-m7" | wc -l | tr -d ' ')"
[[ "$t912_m7_count" -lt 3 ]] ||
  fail "lockless mutant survived: both concurrent entries landed anyway"
echo "PASS 912-devin-trust mutant: dropped lock goes RED"

# -- #951: claude folder-trust seeding ---------------------------------------
# Helpers (claude_spawn_at / claude_trust_entry / claude_trust_mutant) live
# with spawn_base above. Every case runs on a fixture HOME under $TMP.

# AC1: fresh HOME — no .claude.json — gets exactly one projects entry keyed by
# the resolved spawn cwd, file mode 0600, and the spawn proceeds.
t951_home="$TMP/t951-home-fresh"; mkdir -p "$t951_home" "$TMP/t951-cwd-fresh"
t951_out="$(claude_spawn_at "$t951_home" "$TMP/t951-cwd-fresh" t951a "$(mint_task)" 2>&1)" ||
  fail "claude spawn over a fresh HOME failed: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "claude trust-seed spawn lost its OK line: $t951_out"
t951_resolved="$(cd "$TMP/t951-cwd-fresh" && pwd -P)"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "fresh .claude.json lacks the trust entry: $(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$t951_home/.claude.json")" == 0o600 ]] ||
  fail "fresh .claude.json mode is not 0600"
[[ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["projects"]))' "$t951_home/.claude.json")" == 1 ]] ||
  fail "fresh .claude.json gained extra project entries"
echo "PASS 951-claude-trust fresh HOME seeds only the resolved cwd"

# AC1/AC2: an existing store keeps every other key and every other project
# entry; only hasTrustDialogAccepted is set on the spawn cwd's own entry —
# entry keys it already had survive, file mode preserved.
t951_home="$TMP/t951-home-keep"; mkdir -p "$t951_home" "$TMP/t951-cwd-keep"
t951_resolved="$(cd "$TMP/t951-cwd-keep" && pwd -P)"
python3 - "$t951_home/.claude.json" "$t951_resolved" <<'PY'
import json, sys
doc = {"userID": "fixture-user", "numStartups": 7, "greeting": "한글 claude",
       "projects": {"/other/trusted": {"hasTrustDialogAccepted": True, "allowedTools": ["Bash(ls)"]},
                    "/other/untrusted": {"hasTrustDialogAccepted": False, "note": "keep"},
                    sys.argv[2]: {"note": "pre-existing"}}}
with open(sys.argv[1], "w", encoding="utf-8") as h:
    json.dump(doc, h, indent=2, ensure_ascii=False)
PY
chmod 640 "$t951_home/.claude.json"
claude_spawn_at "$t951_home" "$TMP/t951-cwd-keep" t951b "$(mint_task)" >/dev/null ||
  fail "claude spawn over an existing store failed"
python3 - "$t951_home/.claude.json" "$t951_resolved" <<'PY' || fail "seeded store lost keys, projects, or entry keys"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["userID"] == "fixture-user" and data["numStartups"] == 7
projs = data["projects"]
assert len(projs) == 3
assert projs["/other/trusted"] == {"hasTrustDialogAccepted": True, "allowedTools": ["Bash(ls)"]}
assert projs["/other/untrusted"] == {"hasTrustDialogAccepted": False, "note": "keep"}
assert projs[sys.argv[2]] == {"hasTrustDialogAccepted": True, "note": "pre-existing"}
PY
# r2 nit N1: non-ASCII content must survive as raw UTF-8, not XXXX escapes.
grep -q '한글' "$t951_home/.claude.json" ||
  fail "non-ASCII value was escaped to \\uXXXX escapes"
[[ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$t951_home/.claude.json")" == 0o640 ]] ||
  fail "existing store mode changed"
echo "PASS 951-claude-trust preserves other keys, projects, entry keys, mode"

# AC1: a projects entry that says hasTrustDialogAccepted=false is flipped to
# true; an already-true entry is a pure no-op — bytes unchanged.
t951_home="$TMP/t951-home-flip"; mkdir -p "$t951_home" "$TMP/t951-cwd-flip"
t951_resolved="$(cd "$TMP/t951-cwd-flip" && pwd -P)"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":false,"keep":"x"}}}\n' "$t951_resolved" >"$t951_home/.claude.json"
claude_spawn_at "$t951_home" "$TMP/t951-cwd-flip" t951c "$(mint_task)" >/dev/null ||
  fail "claude spawn over a false-flag entry failed"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true,"keep":"x"}' ]] ||
  fail "false flag was not flipped or entry keys were lost: $(claude_trust_entry "$t951_home/.claude.json" "$t951_resolved")"
t951_home="$TMP/t951-home-same"; mkdir -p "$t951_home" "$TMP/t951-cwd-same"
t951_resolved="$(cd "$TMP/t951-cwd-same" && pwd -P)"
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$t951_resolved" >"$t951_home/.claude.json"
cp "$t951_home/.claude.json" "$TMP/t951-same.before"
claude_spawn_at "$t951_home" "$TMP/t951-cwd-same" t951d "$(mint_task)" >/dev/null ||
  fail "claude spawn over an already-trusted cwd failed"
cmp -s "$t951_home/.claude.json" "$TMP/t951-same.before" ||
  fail "already-trusted cwd rewrote the store"
echo "PASS 951-claude-trust false-flag flips, already-trusted is a pure no-op"

# AC1: the projects key is the physical path — a -c through a symlink records
# the resolved directory, never the link spelling.
mkdir -p "$TMP/t951-real/deep" "$TMP/t951-home-link"
ln -s "$TMP/t951-real/deep" "$TMP/t951-link"
claude_spawn_at "$TMP/t951-home-link" "$TMP/t951-link" t951e "$(mint_task)" >/dev/null ||
  fail "claude spawn over a symlinked cwd failed"
t951_resolved="$(cd "$TMP/t951-link" && pwd -P)"
[[ "$t951_resolved" != "$TMP/t951-link" ]] || fail "fixture flaw: symlink resolved to itself"
[[ "$(claude_trust_entry "$TMP/t951-home-link/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "resolved path was not keyed: $(claude_trust_entry "$TMP/t951-home-link/.claude.json" "$t951_resolved")"
[[ "$(claude_trust_entry "$TMP/t951-home-link/.claude.json" "$TMP/t951-link")" == absent ]] ||
  fail "symlink spelling was recorded as a projects key"
echo "PASS 951-claude-trust keys the resolved physical path"

# AC1: CLAUDE_CONFIG_DIR relocates the store — the flag lands under the config
# dir and the HOME-level file is never created.
t951_home="$TMP/t951-home-cfg"; t951_cfg="$TMP/t951-cfgdir"
mkdir -p "$t951_home" "$t951_cfg" "$TMP/t951-cwd-cfg"
env HOME="$t951_home" CLAUDE_CONFIG_DIR="$t951_cfg" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr-t951cfg.log" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel-t951cfg.log" WRK_REFRESH_LOG="$TMP/refresh-t951cfg.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-t951cfg.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t951-cwd-cfg" -m sonnet -p "$PROMPT" -w w -l t951cfg \
  --t T1 --task "$(mint_task)" >/dev/null ||
  fail "CLAUDE_CONFIG_DIR claude spawn failed"
t951_resolved="$(cd "$TMP/t951-cwd-cfg" && pwd -P)"
[[ "$(claude_trust_entry "$t951_cfg/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "CLAUDE_CONFIG_DIR store lacks the trust entry"
[[ ! -e "$t951_home/.claude.json" ]] ||
  fail "HOME-level .claude.json was written despite CLAUDE_CONFIG_DIR"
echo "PASS 951-claude-trust honors CLAUDE_CONFIG_DIR"

# AC2: an unwritable store warns and the spawn continues — fail-open, never a
# denial. The lock file pre-exists so the refusal lands on the atomic write.
t951_home="$TMP/t951-home-ro"; mkdir -p "$t951_home" "$TMP/t951-cwd-ro"
printf '{"projects":{}}\n' >"$t951_home/.claude.json"
: >"$t951_home/.claude.json.wrk.lock"
chmod 555 "$t951_home"
set +e
t951_out="$(claude_spawn_at "$t951_home" "$TMP/t951-cwd-ro" t951f "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
chmod 755 "$t951_home"
[[ "$t951_rc" -eq 0 ]] || fail "unwritable store denied the spawn rc=$t951_rc: $t951_out"
grep -q 'Claude folder trust' <<<"$t951_out" ||
  fail "unwritable store lost its warning: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "unwritable-store spawn lost its OK line: $t951_out"
[[ "$(cat "$t951_home/.claude.json")" == '{"projects":{}}' ]] ||
  fail "unwritable store was modified"
echo "PASS 951-claude-trust unwritable store warns and continues"

# AC2: a corrupt store warns, is not overwritten, and the spawn continues.
t951_home="$TMP/t951-home-corrupt"; mkdir -p "$t951_home" "$TMP/t951-cwd-corrupt"
printf '{ not json\n' >"$t951_home/.claude.json"
cp "$t951_home/.claude.json" "$TMP/t951-corrupt.before"
set +e
t951_out="$(claude_spawn_at "$t951_home" "$TMP/t951-cwd-corrupt" t951g "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
[[ "$t951_rc" -eq 0 ]] || fail "corrupt store denied the spawn rc=$t951_rc: $t951_out"
grep -q 'not valid JSON' <<<"$t951_out" ||
  fail "corrupt-store warning lost its diagnostic: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "corrupt-store spawn lost its OK line: $t951_out"
cmp -s "$t951_home/.claude.json" "$TMP/t951-corrupt.before" ||
  fail "corrupt store was overwritten"
echo "PASS 951-claude-trust corrupt store warns, untouched, spawn continues"

# AC3: a non-claude-kind spawn never touches .claude.json.
t951_home="$TMP/t951-home-codex"; mkdir -p "$t951_home"
claude_spawn_at "$t951_home" "$ROOT" t951h "$(mint_task)" codex-terra >/dev/null ||
  fail "codex-kind spawn failed"
[[ ! -e "$t951_home/.claude.json" ]] ||
  fail "non-claude spawn wrote .claude.json"
[[ ! -e "$t951_home/.claude.json.wrk.lock" ]] ||
  fail "non-claude spawn left a lock file"
echo "PASS 951-claude-trust non-claude kinds never touch the store"

# AC1/AC2: two concurrent spawns into the same store — both entries must land.
# The test delay holds each writer's read->write gap open so a lost update
# would be deterministic, not luck.
t951_home="$TMP/t951-home-race"; mkdir -p "$t951_home" "$TMP/t951-race-a" "$TMP/t951-race-b"
t951_ta="$(mint_task)" t951_tb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.5 \
  claude_spawn_at "$t951_home" "$TMP/t951-race-a" t951ra "$t951_ta" \
  >"$TMP/t951-race-a.out" 2>&1 &
t951_pa=$!
WRK_TEST_TRUST_DELAY_S=0.5 \
  claude_spawn_at "$t951_home" "$TMP/t951-race-b" t951rb "$t951_tb" \
  >"$TMP/t951-race-b.out" 2>&1 &
t951_pb=$!
set +e
wait "$t951_pa"; t951_ra=$?
wait "$t951_pb"; t951_rb=$?
set -e
[[ "$t951_ra" -eq 0 && "$t951_rb" -eq 0 ]] ||
  fail "concurrent claude spawns failed rc=$t951_ra/$t951_rb: $(cat "$TMP/t951-race-a.out" "$TMP/t951-race-b.out")"
t951_ra_path="$(cd "$TMP/t951-race-a" && pwd -P)"
t951_rb_path="$(cd "$TMP/t951-race-b" && pwd -P)"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_ra_path")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "concurrent spawn lost entry A"
[[ "$(claude_trust_entry "$t951_home/.claude.json" "$t951_rb_path")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "concurrent spawn lost entry B"
echo "PASS 951-claude-trust concurrent spawns keep both entries"

# AC2 (r2 blocker B1): HOME unset entirely must warn and continue — under
# set -u an unguarded $HOME expansion aborts before the fail-open guard.
mkdir -p "$TMP/t951-cwd-nohome" "$TMP/t951-xdg-nohome"
set +e
t951_out="$(env -u HOME -u CLAUDE_CONFIG_DIR \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  XDG_DATA_HOME="$TMP/t951-xdg-nohome" \
  ARBITER_INBOX_ROOT="$TMP/t951-inbox-noh" \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr-t951noh.log" \
  WRK_FIXTURE_MARKER="" WRK_SCOPEFUEL_LOG="$TMP/scopefuel-t951noh.log" \
  WRK_REFRESH_LOG="$TMP/refresh-t951noh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-t951noh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t951-cwd-nohome" -m sonnet -p "$PROMPT" -w w \
  -l t951noh --t T1 --task "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
[[ "$t951_rc" -eq 0 ]] || fail "unset HOME denied the spawn rc=$t951_rc: $t951_out"
grep -q 'Claude folder trust' <<<"$t951_out" ||
  fail "unset-HOME spawn lost its warning: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "unset-HOME spawn lost its OK line: $t951_out"
# HOME unset + CLAUDE_CONFIG_DIR set still seeds — the cfg dir does not need HOME.
t951_cfg="$TMP/t951-cfg-nohome"; mkdir -p "$t951_cfg" "$TMP/t951-cwd-nohome2"
env -u HOME CLAUDE_CONFIG_DIR="$t951_cfg" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" WRK_COMPLETION_INTERVAL_S=3600 \
  XDG_DATA_HOME="$TMP/t951-xdg-nohome" \
  ARBITER_INBOX_ROOT="$TMP/t951-inbox-noh" \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr-t951noh2.log" \
  WRK_FIXTURE_MARKER="" WRK_SCOPEFUEL_LOG="$TMP/scopefuel-t951noh2.log" \
  WRK_REFRESH_LOG="$TMP/refresh-t951noh2.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh-t951noh2.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$TMP/t951-cwd-nohome2" -m sonnet -p "$PROMPT" -w w \
  -l t951noh2 --t T1 --task "$(mint_task)" >/dev/null ||
  fail "HOME-unset + CLAUDE_CONFIG_DIR spawn failed"
t951_resolved="$(cd "$TMP/t951-cwd-nohome2" && pwd -P)"
[[ "$(claude_trust_entry "$t951_cfg/.claude.json" "$t951_resolved")" == '{"hasTrustDialogAccepted":true}' ]] ||
  fail "HOME-unset + CLAUDE_CONFIG_DIR store lacks the trust entry"
echo "PASS 951-claude-trust unset HOME warns and continues"

# AC2 (r2 blocker B2): a lock held by a wedged process must time out and
# continue, not block the spawn forever. The holder keeps LOCK_EX for 15s —
# well past the seeder's 2s test deadline — and is killed once asserted.
t951_home="$TMP/t951-home-held"; mkdir -p "$t951_home" "$TMP/t951-cwd-held"
python3 - "$t951_home/.claude.json.wrk.lock" "$TMP/t951-held.ready" <<'PY' &
import fcntl, sys, time
fd = open(sys.argv[1], "w")
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(15)
PY
t951_holder=$!
for _ in $(seq 100); do [[ -e "$TMP/t951-held.ready" ]] && break; sleep 0.05; done
[[ -e "$TMP/t951-held.ready" ]] || fail "lock holder never acquired"
set +e
t951_out="$(WRK_TEST_TRUST_LOCK_TIMEOUT_S=2 \
  claude_spawn_at "$t951_home" "$TMP/t951-cwd-held" t951held "$(mint_task)" 2>&1)"
t951_rc=$?
set -e
kill "$t951_holder" 2>/dev/null || true
wait "$t951_holder" 2>/dev/null || true
[[ "$t951_rc" -eq 0 ]] || fail "held lock denied the spawn rc=$t951_rc: $t951_out"
grep -q 'timed out waiting for lock' <<<"$t951_out" ||
  fail "held lock lost its timeout warning: $t951_out"
grep -q '^OK ' <<<"$t951_out" || fail "held-lock spawn lost its OK line: $t951_out"
echo "PASS 951-claude-trust held lock times out, spawn continues"

# -- assertion-RED mutants ---------------------------------------------------
# 1) other keys dropped: the write must carry the whole document, not just our
#    entry — a mutant that rewrites only the projects subtree loses data.
t951_home="$TMP/t951-home-m1"; mkdir -p "$t951_home" "$TMP/t951-m1-cwd"
python3 - "$t951_home/.claude.json" <<'PY'
import json, sys
json.dump({"keep": 1, "projects": {"/other": {"hasTrustDialogAccepted": True}}},
          open(sys.argv[1], "w", encoding="utf-8"))
PY
# ensure_ascii=False keeps this anchor unique — devin's blob line lacks it.
claude_trust_mutant drop-keys \
  '        blob = json.dumps(data, indent=2, ensure_ascii=False).encode("utf-8")
' \
  '        blob = json.dumps({"projects": {target: entry}}, indent=2, ensure_ascii=False).encode("utf-8")
'
WRK_UNDER_TEST="$TMP/mut-wrk-drop-keys" \
  claude_spawn_at "$t951_home" "$TMP/t951-m1-cwd" t951m1 "$(mint_task)" \
  >/dev/null 2>&1 || true
python3 - "$t951_home/.claude.json" <<'PY' || fail "key-dropping mutant survived: all keys were preserved anyway"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "keep" not in data and len(data["projects"]) == 1, \
    "mutant did not take effect: %r" % data
PY
echo "PASS 951-claude-trust mutant: dropped keys go RED"

# 2) fail-open stripped: without the || warn guard the helper's refusal
#    propagates under set -e and the corrupt-store spawn dies — the exact
#    denial the AC forbids.
t951_home="$TMP/t951-home-m2"; mkdir -p "$t951_home" "$TMP/t951-m2-cwd"
printf '{ not json\n' >"$t951_home/.claude.json"
claude_trust_mutant no-failopen \
  "<<'PY' || warn \"Claude folder trust seed failed; spawn continues\"" \
  "<<'PY'"
set +e
WRK_UNDER_TEST="$TMP/mut-wrk-no-failopen" \
  claude_spawn_at "$t951_home" "$TMP/t951-m2-cwd" t951m2 "$(mint_task)" \
  >/dev/null 2>&1
t951_rc=$?
set -e
[[ "$t951_rc" -ne 0 ]] ||
  fail "fail-open-stripping mutant survived: corrupt store still spawned"
echo "PASS 951-claude-trust mutant: stripped fail-open guard goes RED"

# 3) lock dropped: with the read->write gap held open, two writers lose one
#    entry — the concurrency assertions above must fail against this mutant.
#    The LOCK_NB spelling keeps this anchor unique to claude's poll loop
#    (devin's flock is a bare LOCK_EX before 'try:try').
t951_home="$TMP/t951-home-m7"; mkdir -p "$t951_home" "$TMP/t951-m7-a" "$TMP/t951-m7-b"
claude_trust_mutant nolock \
  '            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break' \
  '            pass  # mutant: no flock
            break'
t951_ma="$(mint_task)" t951_mb="$(mint_task)"
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  claude_spawn_at "$t951_home" "$TMP/t951-m7-a" t951ma "$t951_ma" \
  >/dev/null 2>&1 &
t951_pa=$!
WRK_TEST_TRUST_DELAY_S=0.6 WRK_UNDER_TEST="$TMP/mut-wrk-nolock" \
  claude_spawn_at "$t951_home" "$TMP/t951-m7-b" t951mb "$t951_mb" \
  >/dev/null 2>&1 &
t951_pb=$!
wait "$t951_pa" "$t951_pb" || true
t951_m7_entries="$(python3 - "$t951_home/.claude.json" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1], encoding="utf-8"))["projects"]))
PY
)"
[[ "$t951_m7_entries" -lt 2 ]] ||
  fail "lockless mutant survived: both concurrent entries landed anyway"
echo "PASS 951-claude-trust mutant: dropped lock goes RED"

# ROB-1252: cc-qwen38/cc-glm must refuse to spawn when the clinepass gate key
# file is missing, rather than silently spawning without ANTHROPIC_AUTH_TOKEN.
run_fail env CLINEPASS_GATE_KEY_FILE="$TMP/nonexistent-gate-key.txt" \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m cc-qwen38 -p "$PROMPT" -w w -l fixture --t T1

# ROB-1188/ROB-1190 ③-1: ultra 폐기 — codex-ultra/codex-luna-ultra 는 이제 unknown profile.
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m codex-ultra -p "$PROMPT" -w w -l fixture
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m codex-luna-ultra -p "$PROMPT" -w w -l fixture

: >"$TMP/herdr.log"
spawn_base codex-med >/dev/null
grep -q 'model_reasoning_effort=medium' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base codex-med --effort high >/dev/null
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base codex-sol >/dev/null
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base kiro-sol --effort low >/dev/null
grep -q -- '--effort low' "$TMP/herdr.log"
grep -q '/effort low' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kiro-sol -p "$PROMPT" -w w -l fixture --effort ultra

: >"$TMP/herdr.log"
spawn_base kimi-k3 >/dev/null
kimi_k3_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k3_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/k3' ]] ||
  fail "kimi-k3 start argv snapshot mismatch: $kimi_k3_start"
: >"$TMP/herdr.log"
spawn_base kimi-k27 >/dev/null
kimi_k27_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k27_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/kimi-for-coding' ]] ||
  fail "kimi-k27 start argv snapshot mismatch: $kimi_k27_start"
: >"$TMP/herdr.log"
spawn_base kimi-k27-code >/dev/null
kimi_k27_code_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_k27_code_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/kimi-for-coding' ]] ||
  fail "kimi-k27-code start argv snapshot mismatch: $kimi_k27_code_start"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k3 -p "$PROMPT" -w w -l fixture --effort high
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k27-code -p "$PROMPT" -w w -l fixture --effort high

# ROB-1307: kimi(0.37.2)는 trust 파일명을 basename 소문자화 + 앞 40자로 정규화해
# 조회한다. 대문자·40자 초과 worktree 이름에서 시딩이 어긋나 Trust 다이얼로그가 스폰을
# 죽였다(orch-mock 실측 2회). 시딩 파일명이 kimi 정규화와 일치하는지 고정한다.
KIMI_TRUST_CWD="$TMP/UPPER-Case-ROB-9999-Very-Long-Worktreex-Tail-Extra"
mkdir -p "$KIMI_TRUST_CWD"
KIMI_TEST_HOME="$TMP/kimi-home"
: >"$TMP/herdr.log"
env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  ARBITER_BIN="$TMP/absent-arbiter" KIMI_CODE_HOME="$KIMI_TEST_HOME" \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$KIMI_TRUST_CWD" -m kimi-k3 -p "$PROMPT" -w w -l fixture --t T1 >/dev/null
kimi_abs="$(cd "$KIMI_TRUST_CWD" && pwd -P)"
kimi_base="$(printf '%s' "${kimi_abs##*/}" | tr '[:upper:]' '[:lower:]')"
kimi_base="${kimi_base:0:40}"
while [[ -n "$kimi_base" && ! "${kimi_base: -1}" =~ [a-z0-9] ]]; do kimi_base="${kimi_base%?}"; done
kimi_digest="$(printf '%s' "$kimi_abs" | shasum -a 256 | awk '{print $1}')"
kimi_expected="$KIMI_TEST_HOME/workspace-trust/wd_${kimi_base}_${kimi_digest:0:12}"
[[ -f "$kimi_expected" ]]
grep -q "\"root\":\"$kimi_abs\"" "$kimi_expected"
# 원형(대문자·미절단) 이름으로는 쓰이지 않아야 한다 — 그게 이번 버그였다.
[[ ! -e "$KIMI_TEST_HOME/workspace-trust/wd_${kimi_abs##*/}_${kimi_digest:0:12}" ]]
echo "PASS kimi-trust-canonical-filename"

# kimi-k3-low: same argv as kimi-k3, but KIMI_CODE_HOME must be injected via the
# tab-create --env mechanism (LANE_ENV/TAB_ENV precedent), scoped to only this
# profile — kimi-k3/kimi-k27 must NOT get KIMI_CODE_HOME.
: >"$TMP/herdr.log"
spawn_base kimi-k3-low >/dev/null
kimi_low_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$kimi_low_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/k3' ]] ||
  fail "kimi-k3-low start argv snapshot mismatch: $kimi_low_start"
grep -q -- '--env KIMI_CODE_HOME=' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m kimi-k3-low -p "$PROMPT" -w w -l fixture --effort high
: >"$TMP/herdr.log"
spawn_base kimi-k3 >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi
: >"$TMP/herdr.log"
spawn_base kimi-k27 >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi
: >"$TMP/herdr.log"
spawn_base kimi-k27-code >/dev/null
if grep -q -- 'KIMI_CODE_HOME' "$TMP/herdr.log"; then exit 1; fi

# Task 612: kimi-clone-home must carry kimi-code/ namespace config into the clone
# byte-identically (a fresh kimi 2.0.2 install — e.g. desktop — has only
# `kimi-code/*` model entries, and the clone is what kimi-k3-low runs against).
CLONE_SRC="$TMP/kimi-src-home"
CLONE_DEST="$TMP/kimi-low-home"
mkdir -p "$CLONE_SRC/credentials" "$CLONE_SRC/oauth" "$CLONE_SRC/sessions" "$CLONE_SRC/logs"
cat >"$CLONE_SRC/config.toml" <<'EOF'
default_model = "kimi-code/k3"

[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"

[providers."managed:kimi-code".oauth]
storage = "file"
key = "oauth/kimi-code"

[models."kimi-code/k3"]
provider = "managed:kimi-code"
model = "k3"

[models."kimi-code/kimi-for-coding"]
provider = "managed:kimi-code"
model = "kimi-for-coding"

[thinking]
effort = "high"
EOF
printf 'fixture-credential\n' >"$CLONE_SRC/credentials/kimi-code.json"
printf 'fixture-oauth\n' >"$CLONE_SRC/oauth/kimi-code"
printf 'fixture-device-id\n' >"$CLONE_SRC/device_id"
printf 'fixture-session\n' >"$CLONE_SRC/sessions/s1.jsonl"
printf 'fixture-log\n' >"$CLONE_SRC/logs/l1.log"
env KIMI_CODE_SRC="$CLONE_SRC" KIMI_CODE_LOW_HOME="$CLONE_DEST" \
  "$ROOT/bin/kimi-clone-home" >/dev/null
# The clone config must equal the source byte-for-byte except the [thinking]
# effort rewrite to "low" — compare against a literal expected file so a
# lossy clone (dropped lines, missing entries) fails here.
cat >"$TMP/config-expected.toml" <<'EOF'
default_model = "kimi-code/k3"

[providers."managed:kimi-code"]
type = "kimi"
base_url = "https://api.kimi.com/coding/v1"

[providers."managed:kimi-code".oauth]
storage = "file"
key = "oauth/kimi-code"

[models."kimi-code/k3"]
provider = "managed:kimi-code"
model = "k3"

[models."kimi-code/kimi-for-coding"]
provider = "managed:kimi-code"
model = "kimi-for-coding"

[thinking]
effort = "low"
EOF
cmp "$TMP/config-expected.toml" "$CLONE_DEST/config.toml" ||
  fail "clone config.toml must equal source except [thinking] effort=low"
[[ -f "$CLONE_DEST/credentials/kimi-code.json" ]] || fail "clone must carry credentials/"
[[ -f "$CLONE_DEST/oauth/kimi-code" ]] || fail "clone must carry oauth/"
[[ -f "$CLONE_DEST/device_id" ]] || fail "clone must carry device_id"
[[ ! -e "$CLONE_DEST/sessions" ]] || fail "clone must not carry sessions/"
[[ ! -e "$CLONE_DEST/logs" ]] || fail "clone must not carry logs/"
# The clone rewrite must not touch the source home.
grep -q 'effort = "high"' "$CLONE_SRC/config.toml" ||
  fail "source config.toml must stay untouched"
echo "PASS kimi-clone-home copies kimi-code/ namespace entries verbatim"

# ROB-1191 ⑥: Claude opus/sonnet effort wiring via CLI argv (settings.json never written).
SETTINGS_PATH="${HOME}/.claude/settings.json"
if [[ -f "$SETTINGS_PATH" ]]; then
  SETTINGS_SHA_BEFORE="$(shasum -a 256 "$SETTINGS_PATH" | awk '{print $1}')"
else
  SETTINGS_SHA_BEFORE=""
fi
: >"$TMP/herdr.log"
spawn_base opus --effort xhigh >/dev/null
grep -q -- '--effort xhigh' "$TMP/herdr.log"
grep -q -- '--model opus' "$TMP/herdr.log"
# Default effort for opus is high even without override (ROB-591).
: >"$TMP/herdr.log"
spawn_base opus >/dev/null
grep -q -- '--effort high' "$TMP/herdr.log"
# sonnet default=high; override works; fable still rejects --effort
: >"$TMP/herdr.log"
spawn_base sonnet >/dev/null
grep -q -- '--effort high' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base sonnet --effort medium >/dev/null
grep -q -- '--effort medium' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base haiku >/dev/null
grep -q -- '--model haiku' "$TMP/herdr.log"
grep -q -- '--effort low' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base haiku --effort low >/dev/null
grep -q -- '--model haiku' "$TMP/herdr.log"
grep -q -- '--effort low' "$TMP/herdr.log"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --effort high
if [[ -n "$SETTINGS_SHA_BEFORE" ]]; then
  SETTINGS_SHA_AFTER="$(shasum -a 256 "$SETTINGS_PATH" | awk '{print $1}')"
  [[ "$SETTINGS_SHA_BEFORE" == "$SETTINGS_SHA_AFTER" ]]
else
  # Suite HOME is a fixture that starts without the file — a settings write
  # under it is exactly the regression this check exists to catch.
  [[ ! -f "$SETTINGS_PATH" ]] ||
    fail "claude spawns created ~/.claude/settings.json"
fi

: >"$TMP/herdr.log"
spawn_base oc-kimi-code >/dev/null
grep -q 'send-keys w:p1 return' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base oc-omni >/dev/null
grep -q -- '--model omniroute/auto/coding' "$TMP/herdr.log"
grep -q 'send-keys w:p1 return' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base oc-qwen37-max >/dev/null
grep -q -- '--model cline-pass/cline-pass/qwen3.7-max' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base oc-minimax-m3 >/dev/null
grep -q -- '--model cline-pass/cline-pass/minimax-m3' "$TMP/herdr.log"
: >"$TMP/herdr.log"
# Task 210: oc-solar4 kind+args snapshot. A model/kind drift must fail this
# exact-string assertion (not an exception during spawn).
oc_solar4_out="$(spawn_base oc-solar4 2>&1)"
grep -q 'model=oc-solar4' <<<"$oc_solar4_out"
oc_solar4_start_line="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$oc_solar4_start_line" == 'agent start fixture --kind opencode --pane w:p1 --timeout 30000 -- --auto --model upstage/solar-pro4' ]] ||
  fail "oc-solar4 start argv snapshot mismatch: $oc_solar4_start_line"
echo "PASS oc-solar4 kind/args snapshot"
: >"$TMP/herdr.log"
# ROB-591: 기본 grok = 4.7, grok45/grok46 은 둘 다 즉시 롤백용 명시 별칭
spawn_base grok >/dev/null
grep -q -- '-m grok-4.7' "$TMP/herdr.log"
grep -q -- '--effort high' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base grok45 >/dev/null
grep -q -- '-m grok-4.5' "$TMP/herdr.log"
: >"$TMP/herdr.log"
spawn_base grok46 >/dev/null
grep -q -- '-m grok-4.6' "$TMP/herdr.log"
: >"$TMP/herdr.log"
# ROB-1186 at-most-once, now on the #498 rc 4 fallback: the direct herdr
# injection whose --wait fails gets one return and is never sent again.
once_out="$(env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=prompt-wait-fails WRK_FIXTURE_LOG="$TMP/herdr.log" \
  WRK_PANEWIRE_PROMPT=daemon-down \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" "$WRK" spawn \
  -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
grep -q 'model=codex-terra' <<<"$once_out"
grep -q 'landed=yes' <<<"$once_out"
grep -q ' via=herdr-fallback$' <<<"$once_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
[[ "$(grep -c 'agent send-keys w:p1 return' "$TMP/herdr.log")" -eq 1 ]]

# ROB-1321 landing acceptance fixtures. `working` is only a reason to keep
# observing: marker (recent-unwrapped scrollback) or the visible Pasted text
# chip is required before the brief may be called landed.
marker_prompt="$TMP/landing-marker.md"
marker_first_line='marker-source-0123456789012345678901234567890123456789'
marker_expected="${marker_first_line:0:40}"
printf '\n%s\nsecond line\n' "$marker_first_line" >"$marker_prompt"
PROMPT="$marker_prompt"
: >"$TMP/herdr.log"
marker_out="$(TEST_FIXTURE_SCENARIO=landing-marker WRK_FIXTURE_MARKER="$marker_expected" spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$marker_out"
grep -q "$marker_first_line" "$TMP/herdr.log"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]]
echo "PASS marker-positive-landed: $marker_out"

PROMPT="$TMP/prompt.md"
: >"$TMP/herdr.log"
# AC1 RED before ROB-1321: the old implementation emits landed=yes here
# solely because the freshly booted agent reports working. A complete first
# observation window must instead re-inject once and then report landed=no.
working_no_marker_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base codex-terra 2>&1)"
grep -q 'landed=no' <<<"$working_no_marker_out"
grep -q 'action=reinject-once' <<<"$working_no_marker_out"
grep -q 'last_status=working' <<<"$working_no_marker_out"
# #717: pin the codex window itself, not just the verdict path — a ticks-only
# mutant (33 -> 18) or a window mutant (60 -> 30) must both fail here.
grep -q 'window=60s checks=33' <<<"$working_no_marker_out" ||
  fail "codex landing window must stay 60s/33 ticks: $working_no_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac1-working-without-marker-retries-then-no: $working_no_marker_out"

: >"$TMP/herdr.log"
delayed_marker_out="$(TEST_FIXTURE_SCENARIO=landing-delayed-marker spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$delayed_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
[[ "$(grep -c -- '--source recent-unwrapped' "$TMP/herdr.log")" -ge 3 ]]
echo "PASS ac2-delayed-marker-no-retry: $delayed_marker_out"

: >"$TMP/herdr.log"
retry_out="$(TEST_FIXTURE_SCENARIO=landing-retry spawn_base codex-terra 2>&1)"
grep -q 'landed=retry' <<<"$retry_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac3-swallowed-then-retry: $retry_out"

: >"$TMP/herdr.log"
set +e
no_landing_out="$(TEST_FIXTURE_SCENARIO=landing-no spawn_base codex-terra 2>&1)"
no_landing_rc=$?
set -e
[[ "$no_landing_rc" -eq 0 ]]
grep -q 'landed=no' <<<"$no_landing_out"
grep -q 'spawn succeeded but brief landed=no' <<<"$no_landing_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS landed-no-default-exit=$no_landing_rc: $no_landing_out"

: >"$TMP/herdr.log"
set +e
strict_no_landing_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base codex-terra --landing-strict 2>&1)"
strict_no_landing_rc=$?
set -e
[[ "$strict_no_landing_rc" -eq 76 ]]
grep -q '^OK pane=w:p1 .*landed=no' <<<"$strict_no_landing_out"
grep -q 'spawn succeeded but brief landed=no' <<<"$strict_no_landing_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS ac4-landing-strict exit=$strict_no_landing_rc: $strict_no_landing_out"

: >"$TMP/herdr.log"
scrollout_out="$(TEST_FIXTURE_SCENARIO=landing-scrollback-marker spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$scrollout_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'agent read w:p1 --source recent-unwrapped --lines 200' "$TMP/herdr.log"
echo "PASS ac5-scrollback-marker-no-duplicate: $scrollout_out"

: >"$TMP/herdr.log"
pasted_out="$(TEST_FIXTURE_SCENARIO=landing-pasted spawn_base codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$pasted_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
grep -q 'agent read w:p1 --source visible --lines 40' "$TMP/herdr.log"
echo "PASS pasted-chip-queued: $pasted_out"

# task406: a queued grok payload renders as a `N queued, Enter to send now`
# footer with no `──` head. On a shared screen that chip cannot be attributed
# to THIS injection — the r3 tester showed every "grew past baseline" variant
# is still a false positive (self-echo, missed baseline, count growth, another
# sender). The chip is therefore an ambiguous signal, never landed evidence:
# it only suppresses re-injection so a possibly queued payload is not
# duplicated. The transcript marker stays the only positive evidence, and
# other harnesses must keep ignoring the footer.
: >"$TMP/herdr.log"
grok_queued_out="$(TEST_FIXTURE_SCENARIO=grok-queued spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_queued_out" ||
  fail "grok queued footer is ambiguous, not landed evidence: $grok_queued_out"
grep -q 'grok-queue-chip-unattributable' <<<"$grok_queued_out" ||
  fail "grok chip landed=no must name the unattributable reason: $grok_queued_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok queued chip triggered a re-injection: $grok_queued_out"
echo "PASS grok-queued-chip-ambiguous: $grok_queued_out"

# Self-echo with a payload that itself quotes the chip text: the fixture
# echoes the actual injected payload, so this screen genuinely is this
# brief's own echo — and it still must not land.
echo_prompt="$TMP/grok-echo-prompt.md"
printf 'brief literal: 1 queued, Enter to send now (quoted contract text)\n' >"$echo_prompt"
PROMPT="$echo_prompt"
: >"$TMP/herdr.log"
grok_echo_out="$(TEST_FIXTURE_SCENARIO=grok-echo spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_echo_out" ||
  fail "brief self-echo must not land as a grok queue chip: $grok_echo_out"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok self-echo chip triggered a re-injection: $grok_echo_out"
echo "PASS grok-self-echo-no-land: $grok_echo_out"

# Derivation proof: a payload without the chip text must render a different
# post-injection screen, so the observation is a confirmed non-landing rather
# than an ambiguous chip. A fixture that hardcodes the echo would keep showing
# the chip and fail this case. Even then grok is never re-injected (#701).
echo_prompt_b="$TMP/grok-echo-prompt-b.md"
printf 'brief without the queued contract phrase\n' >"$echo_prompt_b"
PROMPT="$echo_prompt_b"
: >"$TMP/herdr.log"
grok_echo_b_out="$(TEST_FIXTURE_SCENARIO=grok-echo spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_echo_b_out" ||
  fail "payload-derived echo screen changed the verdict path: $grok_echo_b_out"
grep -q 'action=reinject-once' <<<"$grok_echo_b_out" &&
  fail "grok must never re-inject: $grok_echo_b_out"
grep -q 'retry=skipped reason=grok-never-reinjected' <<<"$grok_echo_b_out" ||
  fail "grok skip must name its reason: $grok_echo_b_out"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "payload-derived echo triggered a re-injection: $grok_echo_b_out"
echo "PASS grok-echo-screen-from-payload: $grok_echo_b_out"
PROMPT="$TMP/prompt.md"

: >"$TMP/herdr.log"
grok_stale_out="$(TEST_FIXTURE_SCENARIO=grok-stale spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_stale_out" ||
  fail "a footer the transitional pre-prompt screen missed must not land: $grok_stale_out"
echo "PASS grok-missed-footer-no-land: $grok_stale_out"

: >"$TMP/herdr.log"
grok_or_out="$(TEST_FIXTURE_SCENARIO=grok-or-count spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_or_out" ||
  fail "chip-line growth while the queue shrank must not land: $grok_or_out"
echo "PASS grok-or-count-no-land: $grok_or_out"

: >"$TMP/herdr.log"
grok_toctou_out="$(TEST_FIXTURE_SCENARIO=grok-toctou spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_toctou_out" ||
  fail "another sender's queued payload must not land this injection: $grok_toctou_out"
echo "PASS grok-toctou-no-land: $grok_toctou_out"

: >"$TMP/herdr.log"
grok_zero_out="$(TEST_FIXTURE_SCENARIO=grok-zero spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_zero_out" ||
  fail "0 queued must not land: $grok_zero_out"
grep -q 'action=reinject-once' <<<"$grok_zero_out" &&
  fail "0 queued is not a chip, but grok is still never re-injected: $grok_zero_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "0 queued triggered a grok re-injection: $grok_zero_out"
echo "PASS grok-zero-queued-no-land: $grok_zero_out"

# A chip visible only on the first observation still suppresses re-injection,
# and the final warning must keep WHY: the last ticks see no chip, so without
# provenance the reason would decay to working-without-positive-evidence.
: >"$TMP/herdr.log"
grok_transient_out="$(TEST_FIXTURE_SCENARIO=grok-transient spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_transient_out" ||
  fail "transient grok chip must not land: $grok_transient_out"
grep -q 'first_ambiguous_reason=grok-queue-chip-unattributable' <<<"$grok_transient_out" ||
  fail "transient chip lost its ambiguity provenance: $grok_transient_out"
grep -q 'retry=skipped reason=ambiguous-observation' <<<"$grok_transient_out" ||
  fail "transient chip must still suppress re-injection: $grok_transient_out"
[[ "$(grep -c '^agent prompt ' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "transient chip triggered a re-injection: $grok_transient_out"
echo "PASS grok-transient-chip-provenance: $grok_transient_out"

: >"$TMP/herdr.log"
grok_marker_out="$(TEST_FIXTURE_SCENARIO=grok-marker spawn_base grok 2>&1)"
grep -q 'landed=yes' <<<"$grok_marker_out" ||
  fail "transcript marker must stay priority-1 evidence for grok: $grok_marker_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok marker path triggered a re-injection: $grok_marker_out"
echo "PASS grok-marker-priority-landed: $grok_marker_out"

: >"$TMP/herdr.log"
# #701: grok's echo outlives even its extended window, so a confirmed-looking
# non-landing stays landed=no, is never re-injected, and tells the operator to
# re-check the pane after 2 minutes.
grok_no_chip_out="$(TEST_FIXTURE_SCENARIO=landing-working-no-marker spawn_base grok 2>&1)"
grep -q 'landed=no' <<<"$grok_no_chip_out" ||
  fail "grok without the queued footer must stay landed=no: $grok_no_chip_out"
grep -q 'action=reinject-once' <<<"$grok_no_chip_out" &&
  fail "grok negative path must not re-inject: $grok_no_chip_out"
grep -q 'retry=skipped reason=grok-never-reinjected' <<<"$grok_no_chip_out" ||
  fail "grok negative path lost its skip reason: $grok_no_chip_out"
grep -q 'window=150s checks=78' <<<"$grok_no_chip_out" ||
  fail "grok must keep the extended 150s/78-tick landing window: $grok_no_chip_out"
grep -q 're-check the pane after 2 minutes' <<<"$grok_no_chip_out" ||
  fail "grok landed=no must print the re-check hint: $grok_no_chip_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok negative path triggered a re-injection: $grok_no_chip_out"
echo "PASS grok-no-chip-negative: $grok_no_chip_out"

# #701: a grok echo that lands past the default 30s/18-tick window but inside
# grok's 150s/78-tick window is positive evidence — landed=yes, one injection.
: >"$TMP/herdr.log"
grok_slow_out="$(TEST_FIXTURE_SCENARIO=grok-slow-marker spawn_base grok 2>&1)"
grep -q 'landed=yes' <<<"$grok_slow_out" ||
  fail "grok echo inside the extended window must land: $grok_slow_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]] ||
  fail "grok slow-marker triggered a re-injection: $grok_slow_out"
[[ "$(grep -c -- '--source recent-unwrapped' "$TMP/herdr.log")" -ge 60 ]] ||
  fail "grok slow-marker landed before its late echo: $grok_slow_out"
echo "PASS grok-slow-echo-landed: $grok_slow_out"

: >"$TMP/herdr.log"
claude_grok_chip_out="$(TEST_FIXTURE_SCENARIO=grok-queued spawn_base sonnet 2>&1)"
grep -q 'landed=no' <<<"$claude_grok_chip_out" ||
  fail "claude pane must not treat the grok footer as evidence: $claude_grok_chip_out"
# #717: pin the default window on a non-codex non-grok kind.
grep -q 'window=30s checks=18' <<<"$claude_grok_chip_out" ||
  fail "default landing window must stay 30s/18 ticks: $claude_grok_chip_out"
echo "PASS claude-ignores-grok-queued-chip: $claude_grok_chip_out"

: >"$TMP/herdr.log"
opencode_retry_out="$(TEST_FIXTURE_SCENARIO=opencode-retry spawn_base oc-omni 2>&1)"
grep -q 'landed=retry' <<<"$opencode_retry_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 2 ]]
echo "PASS opencode-landing-retry: $opencode_retry_out"

: >"$TMP/herdr.log"
observation_fail_out="$(TEST_FIXTURE_SCENARIO=landing-observation-fails spawn_base codex-terra 2>&1)"
grep -q 'landed=no' <<<"$observation_fail_out"
[[ "$(grep -c 'agent prompt .*fixture prompt' "$TMP/herdr.log")" -eq 1 ]]
echo "PASS ambiguous-observation-no-retry: $observation_fail_out"

# ---------------------------------------------------------------------------
# #498: the spawn brief goes through `panewire prompt` only (hk decision
# 2026-09-21/task498-esc-landing-unify). The panewire fixture models the
# daemon: expect preflight, send through the herdr fixture (so herdr.log still
# counts every injection), submission proof only for claude/codex.
PW_LOG="$TMP/panewire-prompt.log"
pw_reset() { rm -f "$PW_LOG" "$PW_LOG".* "$TMP/herdr.log"; }
pw_calls() { if [[ -f "$PW_LOG" ]]; then grep -c '^prompt ' "$PW_LOG"; else echo 0; fi; }
herdr_briefs() { if [[ -f "$TMP/herdr.log" ]]; then grep -c '^agent prompt .*fixture prompt' "$TMP/herdr.log" || true; else echo 0; fi; }
pw_spawn() { WRK_PANEWIRE_PROMPT_LOG="$PW_LOG" spawn_base "$@"; }

# A-7: expect line, agent-name target, absolute fresh file, no uptake.
pw_reset
pw_out="$(pw_spawn codex-terra 2>&1)"
grep -q 'landed=yes' <<<"$pw_out" || fail "498 baseline spawn must land: $pw_out"
[[ "$(pw_calls)" -eq 1 ]] || fail "498 one panewire prompt call expected"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 exactly one brief injection expected"
grep -q "^prompt from=wrk-spawn:fixture to=fixture file=/.* timeout=60s uptake=\$" "$PW_LOG" ||
  fail "498 panewire prompt argv (name target, absolute file, codex 60s, no uptake): $(cat "$PW_LOG")"
root_physical="$(cd "$ROOT" && pwd -P)"
[[ "$(head -n1 "$PW_LOG.1")" == "expect: name=fixture cwd=$root_physical" ]] ||
  fail "498 expect line: $(head -n1 "$PW_LOG.1")"
diff <(sed '1,2d' "$PW_LOG.1") "$PROMPT" >/dev/null || fail "498 brief body must follow the expect line verbatim"
grep -q ' via=' <<<"$pw_out" && fail "498 panewire path must not annotate via=: $pw_out"
grep -q 'agent prompt w:p1 fixture prompt' "$TMP/herdr.log" || fail "498 brief must reach the pane"
echo "PASS 498-a7-expect-name-cwd-no-uptake"

# #717: the panewire --timeout is a budget of its own, decoupled from the
# landing window — the daemon only proves claude/codex submissions, so for
# every other kind a window-length timeout is dead polling before wrk's own
# observation starts. Pin it per kind: codex 60s (asserted above), grok and
# the default both 30s even though grok's landing window is 150s. The grok
# pin is what kills a re-coupling mutant — codex's timeout equals its window
# either way.
pw_reset
pw_spawn grok >/dev/null 2>&1
grep -q ' timeout=30s ' "$PW_LOG" ||
  fail "grok panewire timeout must be the 30s default, not its 150s window: $(cat "$PW_LOG")"
pw_reset
pw_spawn sonnet >/dev/null 2>&1
grep -q ' timeout=30s ' "$PW_LOG" ||
  fail "default-kind panewire timeout must be 30s: $(cat "$PW_LOG")"
echo "PASS 717-panewire-timeout-decoupled"

# C4: injection only after tab create and agent start.
tab_line="$(grep -n '^tab create' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
start_line="$(grep -n '^agent start' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
brief_line="$(grep -n '^agent prompt .*fixture prompt' "$TMP/herdr.log" | head -n1 | cut -d: -f1)"
(( tab_line < start_line && start_line < brief_line )) ||
  fail "498 order must be tab create < agent start < brief: $tab_line $start_line $brief_line"
echo "PASS 498-c4-injection-after-start"

# A-3: every refusing gate means zero panewire calls and zero injections.
for gate_mode in 3 4 broken; do
  pw_reset
  WRK_GATE_MODE="$gate_mode" pw_spawn codex-terra >/dev/null 2>&1 && fail "498 gate $gate_mode must refuse"
  [[ "$(pw_calls)" -eq 0 && "$(herdr_briefs)" -eq 0 ]] || fail "498 gate $gate_mode refusal still prompted"
done
pw_reset
TEST_FIXTURE_SCENARIO=tab-create-fails pw_spawn codex-terra >/dev/null 2>&1 && fail "498 tab create failure must fail the spawn"
[[ "$(pw_calls)" -eq 0 ]] || fail "498 no prompt without a pane"
echo "PASS 498-a3-gate-refusal-no-prompt"

# C3: the cwd reaches panewire in herdr's spelling when it names the same
# physical directory, else physical. $TMP is under /var/folders, itself a
# symlink to /private/var/folders on macOS; a symlinked worktree adds one more.
pw_cwd_real="$TMP/pw-cwd-real"; mkdir -p "$pw_cwd_real"
ln -sfn "$pw_cwd_real" "$TMP/pw-cwd-link"
pw_cwd_physical="$(cd "$pw_cwd_real" && pwd -P)"
cwd_case() {
  local reported="$1" pane_cwd="$2" out
  pw_reset
  out="$(WRK_PANEWIRE_PROMPT_LOG="$PW_LOG" WRK_FIXTURE_AGENT_CWD="$reported" WRK_PANEWIRE_PANE_CWD="$pane_cwd" \
    env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$TMP/pw-cwd-link" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
  grep -q 'landed=yes' <<<"$out" || fail "498 cwd case reported=$reported pane=$pane_cwd: $out $(head -n1 "$PW_LOG.1" 2>/dev/null)"
  [[ "$(head -n1 "$PW_LOG.1")" == "expect: name=fixture cwd=$pane_cwd" ]] || fail "498 cwd spelling: $(head -n1 "$PW_LOG.1")"
}
cwd_case "" "$pw_cwd_physical"                       # herdr gives no cwd: physical
cwd_case "$pw_cwd_physical" "$pw_cwd_physical"       # herdr reports physical
cwd_case "$TMP/pw-cwd-link" "$TMP/pw-cwd-link"       # herdr reports the logical spelling
# herdr says the pane is somewhere else: wrk must not adopt that spelling;
# panewire's preflight then refuses (rc 5) and nothing is injected.
pw_reset
elsewhere_out="$(WRK_PANEWIRE_PROMPT_LOG="$PW_LOG" WRK_FIXTURE_AGENT_CWD=/ WRK_PANEWIRE_PANE_CWD=/ \
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 WRK_COMPLETION_INTERVAL_S=3600 \
  WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$TMP/pw-cwd-link" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 2>&1)"
[[ "$(head -n1 "$PW_LOG.1")" == "expect: name=fixture cwd=$pw_cwd_physical" ]] || fail "498 foreign cwd adopted"
grep -q 'landed=no' <<<"$elsewhere_out" || fail "498 cwd mismatch must be landed=no: $elsewhere_out"
grep -q 'panewire_rc=5 submit=unsent' <<<"$elsewhere_out" || fail "498 cwd mismatch detail: $elsewhere_out"
[[ "$(herdr_briefs)" -eq 0 ]] || fail "498 cwd mismatch must not inject (no fallback on rc 5)"
echo "PASS 498-c3-cwd-normalized"

# A-6 ①: no uptake mode — a cold-booting pane that already reports working
# still gets the brief (the fixture refuses working targets when uptake is
# set, as prompt.go does).
pw_reset
working_out="$(TEST_FIXTURE_SCENARIO=landing-scrollback-marker pw_spawn codex-terra 2>&1)"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 working target must still receive the brief: $working_out"
grep -q 'landed=yes' <<<"$working_out" || fail "498 working target landing: $working_out"
echo "PASS 498-a6-working-target-injected"

# A-6 ②: panewire's negative verdict on a brief that did land (claude/codex
# rc 6 "submission evidence unproven", transcript shows the brief) is
# corrected by read-only corroboration — landed=yes and no second brief.
for pw_mode in unproven composer; do
  pw_reset
  fn_out="$(WRK_PANEWIRE_PROMPT="$pw_mode" pw_spawn codex-terra 2>&1)"
  grep -q 'landed=yes' <<<"$fn_out" || fail "498 false negative ($pw_mode) must land: $fn_out"
  [[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 false negative ($pw_mode) re-injected"
  grep -q 'reinject' <<<"$fn_out" && fail "498 false negative ($pw_mode) announced a reinject: $fn_out"
done
echo "PASS 498-a6-false-negative-no-duplicate"

# I2: confirmed non-landing re-injects once, through panewire, as a new file.
pw_reset
pw_retry_out="$(TEST_FIXTURE_SCENARIO=landing-retry pw_spawn codex-terra 2>&1)"
grep -q 'landed=retry' <<<"$pw_retry_out" || fail "498 retry: $pw_retry_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] || fail "498 retry must be one extra panewire delivery"
first_file="$(sed -n '1s/.* file=\([^ ]*\) .*/\1/p' "$PW_LOG")"
second_file="$(sed -n '2s/.* file=\([^ ]*\) .*/\1/p' "$PW_LOG")"
[[ -n "$first_file" && "$first_file" != "$second_file" ]] || fail "498 re-injection must use a new file path"
[[ "$first_file" == "$TMP/inbox/fixture/"* || "$first_file" == "$(cd "$TMP" && pwd -P)/inbox/fixture/"* ]] ||
  fail "498 prompt file must live in the (fixture) job dir: $first_file"
pw_reset
pw_never_out="$(TEST_FIXTURE_SCENARIO=landing-no pw_spawn codex-terra 2>&1)"
grep -q 'landed=no' <<<"$pw_never_out" || fail "498 never-lands: $pw_never_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] || fail "498 at most one re-injection"
echo "PASS 498-i2-reinject-once-new-file"

# A-5: rc 4 (no daemon socket = guaranteed unsent) and only rc 4 falls back to
# one direct herdr injection, visible on the OK line; never twice.
pw_reset
fb_out="$(WRK_PANEWIRE_PROMPT=daemon-down pw_spawn codex-terra 2>&1)"
grep -q '^OK pane=w:p1 .*landed=yes.* via=herdr-fallback$' <<<"$fb_out" || fail "498 fallback OK line: $fb_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 fallback must inject exactly once"
pw_reset
set +e
fb_no_out="$(WRK_PANEWIRE_PROMPT=daemon-down TEST_FIXTURE_SCENARIO=landing-working-no-marker pw_spawn codex-terra --landing-strict 2>&1)"
fb_no_rc=$?
set -e
[[ "$fb_no_rc" -eq 76 ]] || fail "498 fallback landed=no strict exit: $fb_no_rc"
grep -q '^OK pane=w:p1 .*landed=no.* via=herdr-fallback$' <<<"$fb_no_out" || fail "498 fallback no OK line: $fb_no_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 fallback must never repeat: $(herdr_briefs)"
grep -q 'reason=fallback-once' <<<"$fb_no_out" || fail "498 fallback no-retry reason: $fb_no_out"
pw_reset
missing_out="$(PANEWIRE_BIN="$TMP/absent-panewire" pw_spawn codex-terra 2>&1)"
grep -q 'landed=yes.* via=herdr-fallback$' <<<"$missing_out" || fail "498 missing panewire binary: $missing_out"
[[ "$(herdr_briefs)" -eq 1 ]] || fail "498 missing panewire: one injection"
# rc 3, rc 5 and both rc 6 flavors never fall back.
for pw_mode in timeout expect-fail rejected-unsent rejected; do
  pw_reset
  set +e
  nf_out="$(WRK_PANEWIRE_PROMPT="$pw_mode" TEST_FIXTURE_SCENARIO=landing-no pw_spawn codex-terra --landing-strict 2>&1)"
  nf_rc=$?
  set -e
  grep -q 'via=herdr-fallback' <<<"$nf_out" && fail "498 $pw_mode must not fall back: $nf_out"
  [[ "$nf_rc" -eq 76 ]] || fail "498 $pw_mode unlanded strict exit: $nf_rc"
  grep -q '^OK pane=w:p1 .*landed=no' <<<"$nf_out" || fail "498 $pw_mode OK line: $nf_out"
  [[ "$(pw_calls)" -eq 1 ]] || fail "498 $pw_mode must not re-deliver"
  want=0; [[ "$pw_mode" == rejected ]] && want=1
  [[ "$(herdr_briefs)" -eq "$want" ]] || fail "498 $pw_mode injections: $(herdr_briefs) want $want"
done
echo "PASS 498-a5-fallback-rc4-only-once"

# A-4: harnesses panewire cannot prove (devin here) keep the pre-#498 verdict
# through corroboration: devin idle after the brief is landed, one brief.
pw_reset
devin_pw_out="$(TEST_FIXTURE_SCENARIO=devin-idle pw_spawn devin-swe2 2>&1)"
grep -q 'landed=yes' <<<"$devin_pw_out" || fail "498 devin landing regressed: $devin_pw_out"
grep -q 'panewire_rc' <<<"$devin_pw_out" && fail "498 devin landed must not carry a failure detail: $devin_pw_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "498 devin one delivery"
echo "PASS 498-a4-devin-corroborated"

# #568: the 2026-09-22 t502-verify duplicate — panewire rc 6 "submission
# evidence unproven" while devin had already consumed the brief. The
# transcript holds the marker folded across a line break and devin reports
# working; neither must trigger a second delivery.
pw_reset
devin_wrapped_out="$(TEST_FIXTURE_SCENARIO=devin-wrapped-marker pw_spawn devin-swe2 2>&1)"
grep -q 'landed=yes' <<<"$devin_wrapped_out" || fail "568 folded-marker devin must land: $devin_wrapped_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "568 folded-marker devin was re-injected"
if grep -q 'reinject' <<<"$devin_wrapped_out"; then fail "568 folded-marker devin announced a reinject: $devin_wrapped_out"; fi
echo "PASS 568-devin-folded-marker-no-duplicate"

# #568 auxiliary evidence: marker absent entirely, devin working after an
# accepted submit — the pane was verified idle before injection, so working
# means it consumed the brief.
pw_reset
devin_working_out="$(TEST_FIXTURE_SCENARIO=devin-working-no-marker pw_spawn devin-swe2 2>&1)"
grep -q 'landed=yes' <<<"$devin_working_out" || fail "568 devin working must land: $devin_working_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "568 devin working was re-injected"
echo "PASS 568-devin-working-status-lands"

# #568: a devin queued banner is unattributable (grok-chip precedent) —
# ambiguous evidence suppresses the re-injection without claiming landed.
pw_reset
devin_queued_out="$(TEST_FIXTURE_SCENARIO=devin-queued pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_queued_out" || fail "568 devin queued must not claim landed: $devin_queued_out"
grep -q 'reason=ambiguous-observation' <<<"$devin_queued_out" ||
  fail "568 devin queued must be ambiguous: $devin_queued_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 1 ]] || fail "568 devin queued was re-injected"
echo "PASS 568-devin-queued-ambiguous-no-reinject"

# #568 negative direction: a devin pane with no evidence at all (status
# unknown — absent from agent list) still gets exactly one re-injection and
# then stops.
pw_reset
devin_none_out="$(TEST_FIXTURE_SCENARIO=devin-no-landing pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_none_out" || fail "568 devin no-landing: $devin_none_out"
grep -q 'action=reinject-once' <<<"$devin_none_out" ||
  fail "568 devin no-landing lost the re-injection: $devin_none_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] ||
  fail "568 devin no-landing must re-inject exactly once: $(pw_calls)/$(herdr_briefs)"
echo "PASS 568-devin-confirmed-nonlanding-reinject-once"

# #568 round-2 (tester blocker): an unconfirmed submit — panewire timed out,
# possibly before anything was sent — must not be upgraded to landed by a
# merely-working devin. The timeout fixture exits before `agent prompt`, so
# herdr_briefs=0 proves nothing was ever injected.
pw_reset
devin_unconf_out="$(TEST_FIXTURE_SCENARIO=devin-working-no-marker WRK_PANEWIRE_PROMPT=timeout \
  pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_unconf_out" ||
  fail "568 unconfirmed+working must not claim landed: $devin_unconf_out"
[[ "$(pw_calls)" -eq 1 && "$(herdr_briefs)" -eq 0 ]] ||
  fail "568 unconfirmed+working must not inject: $(pw_calls)/$(herdr_briefs)"
echo "PASS 568-devin-unconfirmed-working-not-landed"

# #568 round-2/3 (tester blockers): the marker's words in unrelated UI text are
# not a folded marker — an unindented break mid-line, an unindented break at a
# line start, a UI tab on one line (no line break), and an indented break
# mid-line (not after `❭`/line start). A leftmost-match matcher returns on the
# first variant, so ordering is part of the test: every discriminating variant
# must be evaluated. With no other evidence this is confirmed non-landing:
# exactly one re-injection.
pw_reset
devin_coll_out="$(TEST_FIXTURE_SCENARIO=devin-fold-collision pw_spawn devin-swe2 2>&1)"
grep -q 'landed=no' <<<"$devin_coll_out" ||
  fail "568 fold-collision must not claim landed: $devin_coll_out"
grep -q 'action=reinject-once' <<<"$devin_coll_out" ||
  fail "568 fold-collision lost the re-injection: $devin_coll_out"
[[ "$(pw_calls)" -eq 2 && "$(herdr_briefs)" -eq 2 ]] ||
  fail "568 fold-collision must re-inject exactly once: $(pw_calls)/$(herdr_briefs)"
echo "PASS 568-devin-fold-collision-not-marker"

rm -f "$TMP/herdr.log"
blocked3="$(WRK_GATE_MODE=3 spawn_base codex-terra 2>&1 || true)"
grep -q 'gate blocked' <<<"$blocked3"
[[ ! -e "$TMP/herdr.log" ]]
blocked4="$(WRK_GATE_MODE=4 spawn_base codex-terra 2>&1 || true)"
grep -q 'measurement unavailable' <<<"$blocked4"
[[ ! -e "$TMP/herdr.log" ]]
rm -f "$TMP/herdr.log"
unsupported="$(WRK_GATE_MODE=unsupported spawn_base codex-terra 2>&1)"
grep -q 'no gate subcommand' <<<"$unsupported"
[[ -e "$TMP/herdr.log" ]]
rm -f "$TMP/herdr.log"
run_fail env WRK_GATE_MODE=broken HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1
SCOPEFUEL_BIN="$TMP/missing-scopefuel" HERDR_BIN="$HERDR" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture \
  --t T1 >"$TMP/missing.out" 2>&1
grep -q 'scopefuel unavailable; quota gate skipped' "$TMP/missing.out"
grep -q 'scopefuel refresh skipped; gate/arbiter did not provide a pool' "$TMP/missing.out"
grep -q 'model=codex-terra' "$TMP/missing.out"

# ROB-1227 D4: refresh is detached, uses the gate-provided pool, and exposes
# failure/timeout warnings without changing the successful spawn.
: >"$TMP/refresh.log"
start_ns="$(python3 -c 'import time; print(time.time_ns())')"
success_out="$(spawn_base codex-terra 2>&1)"
elapsed_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - start_ns) / 1000000 ))"
grep -q 'model=codex-terra' <<<"$success_out"
[[ "$elapsed_ms" -lt 1800 ]]  # 동일 flake 계열 — 위 timeout 케이스와 같은 근거로 완화
for _ in {1..20}; do
  grep -q '^refresh codex --background$' "$TMP/refresh.log" && break
  sleep 0.05
done
grep -q '^refresh codex --background$' "$TMP/refresh.log"

failed_out="$(WRK_REFRESH_MODE=fail spawn_base codex-terra 2>&1)"
grep -q 'scopefuel refresh failed for pool=codex; spawn already succeeded' <<<"$failed_out"
grep -q 'model=codex-terra' <<<"$failed_out"

timeout_start_ns="$(python3 -c 'import time; print(time.time_ns())')"
: >"$TMP/refresh.pids"
timeout_out="$(WRK_REFRESH_MODE=hang WRK_REFRESH_DELAY=2 WRK_REFRESH_TIMEOUT_S=0.2 spawn_base codex-terra 2>&1)"
timeout_elapsed_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - timeout_start_ns) / 1000000 ))"
# 2s hang 을 기다리지 않았음을 증명하면 충분하다 — 1000ms 는 부하 있는 머신에서
# 오탐(실측 1075ms flake)이라 hang(2000ms) 대비 명확히 짧은 1800ms 로 완화.
[[ "$timeout_elapsed_ms" -lt 1800 ]]
grep -q 'scopefuel refresh timed out for pool=codex; spawn already succeeded' <<<"$timeout_out"
grep -q 'model=codex-terra' <<<"$timeout_out"
while IFS= read -r refresh_pid; do
  [[ -z "$refresh_pid" ]] || ! ps -p "$refresh_pid" -o pid= | grep -q '[0-9]'
done <"$TMP/refresh.pids"

cp "$SCOPEFUEL" "$TMP/non-executable-scopefuel"
chmod -x "$TMP/non-executable-scopefuel"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$TMP/non-executable-scopefuel" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1

# ---------------------------------------------------------------------------
# ROB-1199/ROB-1201: arbiter admission control. wrk holds no pool mapping — arbiter reads
# the pool out of scopefuel's own gate output and validates it against
# `scopefuel --json`. There is no bypass flag; only an absent/too-old arbiter is
# tolerated, and only with a warning.
# ---------------------------------------------------------------------------

# ⑦ arbiter not installed at all → warn, spawn proceeds (installation transition).
rm -f "$TMP/herdr.log"
absent_out="$(spawn_base codex-terra 2>&1)"
grep -q 'arbiter unavailable' <<<"$absent_out"
grep -q 'model=codex-terra' <<<"$absent_out"
[[ -e "$TMP/herdr.log" ]]

# ⑦ installed arbiter that predates the lease subcommand → warn, spawn proceeds.
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-legacy"
legacy_out="$(spawn_base codex-terra 2>&1)"
grep -q 'no lease subcommand' <<<"$legacy_out"
grep -q 'model=codex-terra' <<<"$legacy_out"
[[ -e "$TMP/herdr.log" ]]
unset TEST_ARBITER_BIN

# An arbiter command failure is observational for quota_pool; spawning continues.
cp "$ARBITER" "$TMP/non-executable-arbiter"
chmod -x "$TMP/non-executable-arbiter"
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$TMP/non-executable-arbiter"
nonexec_out="$(spawn_base codex-terra 2>&1)"
grep -q 'quota-pool record unavailable' <<<"$nonexec_out"
grep -q 'model=codex-terra' <<<"$nonexec_out"
[[ -e "$TMP/herdr.log" ]]
unset TEST_ARBITER_BIN

# ⑥ record: the gate passes, arbiter records the pool scopefuel resolved, and the
# worker is handed its own job/resource/profile identity.
export TEST_ARBITER_BIN="$ARBITER"
rm -f "$TMP/herdr.log"
admit_out="$(spawn_base codex-terra --job arb-ok --t T2 2>&1)"
grep -q 'quota_record=codex/quota_pool' <<<"$admit_out"
grep -q 'job=arb-ok' <<<"$admit_out"
grep -q 'ARBITER_JOB=arb-ok' "$TMP/herdr.log"
grep -q 'ARBITER_RESOURCE=codex' "$TMP/herdr.log"
grep -q 'ARBITER_KIND=quota_pool' "$TMP/herdr.log"
grep -q 'ARBITER_PROFILE=codex-terra-max' "$TMP/herdr.log"
grep -q 'ARBITER_STARTED_AT=' "$TMP/herdr.log"
arb status --job arb-ok --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="codex" and r[0]["profile"]=="codex-terra-max", d'
arb status --job arb-ok --json |
  python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"]; assert len(j)==1 and j[0]["t_level"]=="T2" and j[0]["owner_lane"]=="default", j'
python3 - "$ARBITER_INBOX_ROOT/arb-ok/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["agent_label"] == "fixture", event
PY

# Task 201: scopefuel, not wrk, is the sole Devin-pool authority. The fixture's
# stable first line must arrive unchanged at arbiter, while the receipt keeps
# the profile spelling the worker actually launched.
rm -f "$TMP/herdr.log" "$TMP/scopefuel.log"
devin_admit_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-swe2 --job arb-devin --t T1 2>&1)"
grep -qx 'profile=devin-swe2 pool=devin used_pct=0 class=spend' <<<"$devin_admit_out"
grep -q 'quota_record=devin/quota_pool' <<<"$devin_admit_out"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == 'devin-swe2' ]]
arb status --job arb-devin --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="devin" and r[0]["profile"]=="devin-swe2", d'
python3 - "$ARBITER_INBOX_ROOT/arb-devin/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
spawned = next(event for event in events if event["kind"] == "job.spawned")
assert spawned["payload"]["profile"] == "devin-swe2", spawned
PY
echo "PASS devin-swe2 scopefuel-gate-to-arbiter-pool-and-spawn-receipt"

# ---------------------------------------------------------------------------
# task #677: the quota_pool.record launch_profile must carry the canonical
# catalog profile, not the launcher spelling. codex-sol/codex-max/codex/
# builder-sol/captain-sol all run gpt-6.1-sol (#1026), whose catalog profile is
# codex-sol (scopefuel PROFILE_ALIASES: codex-max -> codex-sol; `policy launch
# builder-sol` is not in the catalog at all). Recording the raw spelling split
# reps/usage attribution across names the grade table cannot read — 2026-09-25:
# a builder-sol xhigh spawn recorded launch_profile=builder-sol@xhigh and
# profile=codex-max while its pane ran gpt-6-sol xhigh. The ROB-1213
# cross-checked fields stay put (pool from scopefuel, profile gate-normalized);
# non-codex pools keep their literal spelling@effort, so no other pool's records
# change; rollback spellings (codex-sol56, codex-sol6) stay literal by design —
# builder-sol6 still records codex-sol@high through its grade consult even
# though its model id stays literal.
# Mutant: revert the canonical-name mapping in arbiter_admit -> these go RED.
# ---------------------------------------------------------------------------
# Own arbiter state (like the R20/R21/idempotency sections): these successful
# spawns leave durable quota records behind, and the shared suite inbox later
# asserts on the exact record set (e.g. no claude records after a released
# spawn). Records written here must not leak into that set.
T677_INBOX="$TMP/inbox-677"
T677_XDG="$TMP/xdg-677"
# #912: the devin launch_profile case below is a real spawn; its fixture XDG
# root needs a store that covers $ROOT, like the suite-level seed does.
devin_trust_seed_store "$T677_XDG" "$ROOT"
launch_profile_case() {
  local model="$1" job="$2" expected="$3"; shift 3
  ARBITER_INBOX_ROOT="$T677_INBOX" XDG_DATA_HOME="$T677_XDG" \
    spawn_base "$model" --job "$job" --t T1 "$@" >/dev/null
  python3 - "$T677_INBOX/$job/events" "$expected" "$model" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(event for event in events if event["kind"] == "quota_pool.record")
got = record["payload"]["launch_profile"]
assert got == sys.argv[2], f"{sys.argv[3]}: launch_profile={got!r} expected {sys.argv[2]!r}"
PY
}
# Every codex spelling: the raw aliases collapse onto the canonical catalog
# profile, the spellings that already are canonical stay put, and the ROB-591
# rollback spellings stay literal (they pin the superseded model).
launch_profile_case codex-sol codex-sol-xhigh 'codex-sol@xhigh' --effort xhigh
launch_profile_case builder-sol builder-sol-canon 'codex-sol@high' --role builder --lane builder-sol-lane --parent parent-lane
launch_profile_case captain-sol captain-sol-canon 'codex-sol@high' --role builder --lane captain-sol-lane --parent parent-lane
launch_profile_case codex-max codex-max-canon 'codex-sol@max'
launch_profile_case codex codex-canon 'codex-sol@high'
launch_profile_case codex-sol56 codex-sol56-rollback 'codex-sol56@max'
# #1026: codex-sol6 records its literal spelling@effort like codex-sol56, while
# builder-sol6 still lands on the canonical consult rung codex-sol@high.
launch_profile_case codex-sol6 codex-sol6-rollback 'codex-sol6@max'
launch_profile_case builder-sol6 builder-sol6-canon 'codex-sol@high' --role builder --lane builder-sol6-lane --parent parent-lane
launch_profile_case codex-terra codex-terra-canon 'codex-terra@medium'
launch_profile_case codex-med codex-med-canon 'codex-terra@medium'
launch_profile_case codex-terra-max codex-terra-max-canon 'codex-terra-max@max'
launch_profile_case codex-luna codex-luna-canon 'codex-luna@medium'
launch_profile_case codex-luna-hi codex-luna-hi-canon 'codex-luna@high'
launch_profile_case codex-luna-max codex-luna-max-canon 'codex-luna-max@max'
launch_profile_case codex-luna56 codex-luna56-rollback 'codex-luna56@medium'
launch_profile_case builder-luna builder-luna-canon 'codex-luna@xhigh' --role builder --lane builder-luna-lane --parent parent-lane
# #921: builder-sonnet records the canonical catalog rung on the claude pool,
# not the launcher spelling — sonnet@xhigh by default, sonnet@max on the
# seat-rule exception rung.
launch_profile_case builder-sonnet builder-sonnet-canon 'sonnet@xhigh' --role builder --lane builder-sonnet-canon-lane --parent parent-lane
launch_profile_case builder-sonnet builder-sonnet-canon-max 'sonnet@max' --role builder --lane builder-sonnet-canon-max-lane --parent parent-lane --effort max
launch_profile_case builder-sonnet builder-sonnet-canon-high 'sonnet@high' --role builder --lane builder-sonnet-canon-high-lane --parent parent-lane --effort high
launch_profile_case codex-astra codex-astra-canon 'codex-astra@xhigh'
# Other pools keep their literal spelling@effort — no other pool's record moves.
launch_profile_case devin-swe2 devin-launch-literal 'devin-swe2'
launch_profile_case builder-opus builder-opus-launch-literal 'builder-opus@high' --role builder --lane builder-opus-lane --parent parent-lane
launch_profile_case grok grok-launch-literal 'grok@high'
python3 - "$T677_INBOX/codex-sol-xhigh/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(event for event in events if event["kind"] == "quota_pool.record")
assert record["payload"]["pool"] == "codex", record
assert record["payload"]["profile"] == "codex-max", record
PY
echo "PASS 677 launch_profile carries the canonical catalog profile for codex aliases"

# Task 577 failure cleanup: a bounded welcome timeout occurs after the Devin
# quota record and pane exist. It must emit process diagnostics, close that
# pane, and release this job's arbiter record without touching another Devin
# job's record.
rm -f "$TMP/herdr.log"
set +e
devin_timeout_out="$(TEST_FIXTURE_SCENARIO=devin-wait-timeout spawn_base devin-swe2 --job arb-devin-timeout --t T2 2>&1)"
devin_timeout_rc=$?
set -e
[[ "$devin_timeout_rc" -eq 7 ]] ||
  fail "arbiter-backed Devin timeout expected rc=7, got $devin_timeout_rc: $devin_timeout_out"
grep -q 'Devin pane startup failed: welcome_prompt_footer wait exited 7' <<<"$devin_timeout_out" ||
  fail "Devin timeout lost its readiness diagnostic"
sed -n '/^agent wait /,$p' "$TMP/herdr.log" | grep -qx 'pane process-info --pane w:p1' ||
  fail "Devin timeout omitted process-info"
grep -qx 'pane close w:p1' "$TMP/herdr.log" ||
  fail "Devin timeout leaked its pane"
arb status --job arb-devin-timeout --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["quota_pool_records"] == [], d
'
python3 - "$ARBITER_INBOX_ROOT/arb-devin-timeout/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
assert any(event.get("kind") == "quota_pool.release" for event in events), events
PY
arb status --job arb-devin --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["quota_pool_records"]) == 1 and d["quota_pool_records"][0]["job_id"] == "arb-devin", d
'
echo "PASS task577 Devin timeout closes pane and releases only its arbiter record"

# Task 577 FIX: a pane never detected inside the window fails the same way —
# no rename, pane closed, only this job's arbiter record released.
rm -f "$TMP/herdr.log"
set +e
devin_undetected_out="$(TEST_FIXTURE_SCENARIO=devin-never-detect spawn_base devin-swe2 --job arb-devin-undetected --t T2 2>&1)"
devin_undetected_rc=$?
set -e
[[ "$devin_undetected_rc" -eq 1 ]] ||
  fail "arbiter-backed undetected Devin expected rc=1, got $devin_undetected_rc: $devin_undetected_out"
if grep -q '^agent rename ' "$TMP/herdr.log"; then fail "undetected Devin was renamed"; fi
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "undetected Devin leaked its pane"
arb status --job arb-devin-undetected --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["quota_pool_records"] == [], d
'
arb status --job arb-devin --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["quota_pool_records"]) == 1 and d["quota_pool_records"][0]["job_id"] == "arb-devin", d
'
echo "PASS task577 undetected Devin closes pane and releases only its arbiter record"

# #606 AC3: a shell that never frees the foreground inside the window fails
# closed exactly like any other start failure after the record exists — pane
# closed, this job's quota record released (release event written), and no
# brief delivered. Dropping the release turns this red.
rm -f "$TMP/herdr.log"
set +e
shell_arb_out="$(PATH="$TMP/jumpclock:$PATH" FAKECLOCK_AFTER=never FAKECLOCK_JUMP=0 TEST_FIXTURE_SCENARIO=shell-never-ready spawn_base opus --job arb-shell-busy --t T2 2>&1)"
shell_arb_rc=$?
set -e
[[ "$shell_arb_rc" -eq 1 ]] ||
  fail "arbiter-backed never-ready shell expected rc=1, got $shell_arb_rc: $shell_arb_out"
grep -q 'agent start failed: shell not ready within the 30000ms window' <<<"$shell_arb_out" ||
  fail "arbiter-backed never-ready shell lost its diagnostic: $shell_arb_out"
grep -q 'arbiter quota-pool record released after spawn failure: claude job=arb-shell-busy' <<<"$shell_arb_out" ||
  fail "arbiter-backed never-ready shell did not release its quota record: $shell_arb_out"
grep -qx 'pane close w:p1' "$TMP/herdr.log" || fail "arbiter-backed never-ready shell leaked its pane"
if grep -q '^agent prompt ' "$TMP/herdr.log"; then fail "arbiter-backed never-ready shell delivered a brief"; fi
arb status --job arb-shell-busy --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["quota_pool_records"] == [], d
'
python3 - "$ARBITER_INBOX_ROOT/arb-shell-busy/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
assert any(event.get("kind") == "quota_pool.release" for event in events), events
PY
echo "PASS task606 never-ready shell closes pane and releases its arbiter record"

# Task 281: the new devin model variants share scopefuel's single `devin` pool
# — the gate call uses the only devin spelling installed scopefuel accepts
# (devin-swe2), while the spawn receipt keeps the actual launch profile.
rm -f "$TMP/herdr.log" "$TMP/scopefuel.log"
ds41_admit_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base devin-ds41 --job arb-devin-ds41 --t T1 2>&1)"
grep -qx 'profile=devin-swe2 pool=devin used_pct=0 class=spend' <<<"$ds41_admit_out"
grep -q 'quota_record=devin/quota_pool' <<<"$ds41_admit_out"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == 'devin-swe2' ]]
arb status --job arb-devin-ds41 --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=d["quota_pool_records"]; assert len(r)==1 and r[0]["pool"]=="devin" and r[0]["profile"]=="devin-swe2", d'
python3 - "$ARBITER_INBOX_ROOT/arb-devin-ds41/events" <<'PY'
import json, pathlib, sys
events = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob("*.json")]
spawned = next(event for event in events if event["kind"] == "job.spawned")
assert spawned["payload"]["profile"] == "devin-ds41", spawned
PY
echo "PASS devin-ds41 shares the devin-swe2 gate spelling and devin quota pool"

# ⑥ the pool is a record, not a mutex: another job asking for the same pool
# succeeds and both records remain visible.
rm -f "$TMP/herdr.log"
second_out="$(spawn_base codex-terra --job arb-second --t T2 2>&1)"
grep -q 'quota_record=codex/quota_pool' <<<"$second_out"
arb status --json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); r=[x for x in d["quota_pool_records"] if x["pool"]=="codex"]; assert {x["job_id"] for x in r} >= {"arb-ok","arb-second"}, d'

# A different profile mapping to a different pool is unaffected by that denial.
rm -f "$TMP/herdr.log"
other_out="$(spawn_base kiro-sol --job arb-other --t T1 2>&1)"
grep -q 'quota_record=kiro/quota_pool' <<<"$other_out"

# ---------------------------------------------------------------------------
# ROB-1326: a duplicate arbiter job is an exact-once boundary, not an advisory.
# All cases use the existing fixture Herdr and this suite's temporary arbiter DB.
# ---------------------------------------------------------------------------

# AC1: an active row stops before tab creation, with a stable dedicated exit and
# enough evidence for the owner to investigate.
arb claim --job idem-active --agent-label incumbent --lane incumbent-lane --t T2 >/dev/null
rm -f "$TMP/herdr.log"
set +e
active_dup_out="$(spawn_base codex-terra --job idem-active --t T2 2>&1)"
active_dup_rc=$?
set -e
[[ "$active_dup_rc" -eq 74 ]] || { echo "expected active duplicate exit 74, got $active_dup_rc: $active_dup_out" >&2; exit 1; }
grep -q 'job_id=idem-active' <<<"$active_dup_out"
grep -q 'state=claimed' <<<"$active_dup_out"
grep -q 'owner_lane=incumbent-lane' <<<"$active_dup_out"
[[ ! -e "$TMP/herdr.log" ]] || { echo "active duplicate reached Herdr spawn" >&2; exit 1; }
echo "PASS ROB-1326 AC1 active duplicate fail-closed: $active_dup_out"

# AC2: a released row gets the explicit reclaim transition, then spawns once.
arb claim --job idem-released --agent-label released-old --lane released-old-lane --t T1 >/dev/null
arb lease --job idem-released --kind quota_pool --profile codex-terra-max --gate-output <("$SCOPEFUEL" gate -m codex-terra-max) >/dev/null
arb release --job idem-released --resource codex --kind quota_pool >/dev/null
rm -f "$TMP/herdr.log"
released_dup_out="$(spawn_base codex-terra --job idem-released --t T3 2>&1)"
grep -q '^OK ' <<<"$released_dup_out"
[[ -e "$TMP/herdr.log" ]] || { echo "released job did not reach fixture spawn" >&2; exit 1; }
arb job-get --job idem-released --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["state"] == "leased", d
assert d["recent_event_kinds"].count("job.reclaim") == 1, d
'
echo "PASS ROB-1326 AC2 released duplicate reclaimed then spawned: $released_dup_out"

# AC3: once a live arbiter reported duplicate, an unreadable state is itself a
# fail-closed condition.  The proxy fails only the actual lookup, not --help.
arb claim --job idem-unknown --agent-label unknown-owner --lane unknown-lane --t T1 >/dev/null
export REAL_ARBITER="$ARBITER"
export WRK_ARBITER_PROXY_MODE=job-get-fails
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-proxy"
rm -f "$TMP/herdr.log"
set +e
unknown_dup_out="$(spawn_base codex-terra --job idem-unknown --t T1 2>&1)"
unknown_dup_rc=$?
set -e
[[ "$unknown_dup_rc" -eq 75 ]] || { echo "expected unreadable-state exit 75, got $unknown_dup_rc: $unknown_dup_out" >&2; exit 1; }
grep -q 'state lookup failed' <<<"$unknown_dup_out"
[[ ! -e "$TMP/herdr.log" ]] || { echo "unknown duplicate state reached Herdr spawn" >&2; exit 1; }
unset WRK_ARBITER_PROXY_MODE TEST_ARBITER_BIN REAL_ARBITER
echo "PASS ROB-1326 AC3 duplicate lookup failure is fail-closed: $unknown_dup_out"

# AC8: the only active-duplicate escape hatch is explicit and auditable.
export TEST_ARBITER_BIN="$ARBITER"
arb claim --job idem-override --agent-label override-owner --lane override-lane --t T1 >/dev/null
rm -f "$TMP/herdr.log"
override_out="$(spawn_base codex-terra --job idem-override --t T1 --job-dup-ok 2>&1)"
grep -q '^OK ' <<<"$override_out"
grep -q 'job-dup-ok override' <<<"$override_out"
grep -q 'state=claimed' <<<"$override_out"
[[ -e "$TMP/herdr.log" ]] || { echo "explicit duplicate override did not reach Herdr spawn" >&2; exit 1; }
echo "PASS ROB-1326 AC8 explicit active duplicate override: $override_out"

# AC6: a successful fixture spawn writes a queryable receipt.  Its recording
# failure is non-transactional: the pane remains successful but job-get says
# receipt=absent, and wrk emits a warning.
rm -f "$TMP/herdr.log"
receipt_out="$(spawn_base codex-terra --job idem-receipt --t T1 2>&1)"
grep -q '^OK pane=w:p1' <<<"$receipt_out"
arb job-get --job idem-receipt --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["receipt"]
assert r["pane_id"] == "w:p1", d
assert r["spawned_at"], d
assert r["label"] == "fixture", d
assert r["profile"] == "codex-terra", d
assert r["workspace"] == "w", d
assert "job.spawned" in d["recent_event_kinds"], d
'
export REAL_ARBITER="$ARBITER"
export WRK_ARBITER_PROXY_MODE=spawn-receipt-fails
export TEST_ARBITER_BIN="$ROOT/tests/fixtures/arbiter-proxy"
rm -f "$TMP/herdr.log"
receipt_fail_out="$(spawn_base codex-terra --job idem-receipt-fail --t T1 2>&1)"
grep -q '^OK pane=w:p1' <<<"$receipt_fail_out"
grep -q 'job.spawned receipt failed' <<<"$receipt_fail_out"
[[ -e "$TMP/herdr.log" ]] || { echo "receipt failure stopped successful fixture spawn" >&2; exit 1; }
arb job-get --job idem-receipt-fail --json | python3 -c '
import json, sys
assert json.load(sys.stdin)["receipt"] == "absent"
'
unset WRK_ARBITER_PROXY_MODE TEST_ARBITER_BIN REAL_ARBITER
export TEST_ARBITER_BIN="$ARBITER"
echo "PASS ROB-1326 AC6 spawn receipt success and non-transactional receipt failure"

# ⑥ spawn failure releases the record instead of leaking it.
rm -f "$TMP/herdr.log"
export TEST_FIXTURE_SCENARIO=tab-create-fails
rollback_out="$(spawn_base opus --job arb-rollback --t T2 2>&1 || true)"
unset TEST_FIXTURE_SCENARIO
grep -q 'arbiter quota-pool record released after spawn failure: claude job=arb-rollback' <<<"$rollback_out"
arb status --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert not [r for r in d["quota_pool_records"] if r["pool"] == "claude"], d["quota_pool_records"]
events = __import__("pathlib").Path(__import__("os").environ["ARBITER_INBOX_ROOT"], "arb-rollback", "events")
assert any(__import__("json").loads(p.read_text())["kind"] == "quota_pool.release" for p in events.glob("*.json")), events
'
# The released pool can be recorded again right away.
rm -f "$TMP/herdr.log"
retry_out="$(spawn_base opus --job arb-retry --t T2 2>&1)"
grep -q 'quota_record=claude/quota_pool' <<<"$retry_out"

# A released duplicate reclaims the existing row and then records the pool;
# ordinary duplicate claim still never deletes its original history.
arb release --job arb-retry --resource claude --kind quota_pool >/dev/null
rm -f "$TMP/herdr.log"
dup_out="$(spawn_base opus --job arb-retry --t T2 2>&1)"
grep -q "reclaimed" <<<"$dup_out"
grep -q 'quota_record=claude/quota_pool' <<<"$dup_out"
arb job-get --job arb-retry --json | python3 -c 'import json,sys; assert json.load(sys.stdin)["recent_event_kinds"].count("job.reclaim") == 1'

# ⑥ quota_pool record failure warns and still spawns; this is not a quota gate.
cat >"$TMP/quota-record-failing-arbiter" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "lease" && "\$*" == *"quota_pool"* ]]; then
  echo "fixture: quota record unavailable" >&2
  exit 7
fi
exec "$ARBITER" "\$@"
EOF
chmod +x "$TMP/quota-record-failing-arbiter"
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$TMP/quota-record-failing-arbiter"
record_failed_out="$(spawn_base codex-terra --job arb-record-fail --t T1 2>&1)"
grep -q 'arbiter quota-pool record failed' <<<"$record_failed_out"
grep -q 'model=codex-terra' <<<"$record_failed_out"
[[ -e "$TMP/herdr.log" ]]
arb status --job arb-record-fail --json |
  python3 -c 'import json,sys; assert json.load(sys.stdin)["quota_pool_records"] == [], sys.stdin'
unset TEST_ARBITER_BIN

# ---------------------------------------------------------------------------
# task483: --operator-request/--requested-by are forwarded verbatim to
# `scopefuel gate`. wrk owns no REF-format or profile-applicability judgement —
# the fixture mirrors the installed gate's fail-closed refusal vocabulary, and
# wrk must propagate both the refusal text and the exit code. The four gate
# fields (escalation_override/operator_request_ref/requested_by/ref_resolution)
# persist into the spawn log (gate stdout reprint) and the arbiter
# quota_pool.record event, byte-identical to what the gate emitted.
# ---------------------------------------------------------------------------

grep -q -- '--operator-request' <<<"$spawn_help_out" ||
  fail "spawn --help lost --operator-request"
grep -q -- '--requested-by' <<<"$spawn_help_out" ||
  fail "spawn --help lost --requested-by"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --t T1 --operator-request
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m fable -p "$PROMPT" -w w -l fixture --t T1 --requested-by

# Deny-path runs take a private fixture log and a missing hosts.toml: the
# detached completion sentinels left by earlier registered spawns keep
# appending first-probe calls to the shared $TMP/herdr.log, and a configured
# machine's router runs `herdr agent list` for local measurement before the
# gate — both would fake "denied spawn reached Herdr". With no hosts.toml the
# router short-circuits to the local spawn path, so "gate denied before ANY
# Herdr call" stays provable.
spawn_deny() {
  local log="$1" model="$2"; shift 2
  local extra=("$@")
  # #768: --role builder requires --task before the gate these cases probe.
  # Draw from the same pre-minted pool spawn_base uses; worker-role calls keep
  # the suite's HK_TASK_ID env inheritance instead.
  case " ${extra[*]-} " in
    *" --task "*|*" --parent-job "*) ;;
    *" --role builder "*)
      extra+=(--task "$(mint_task)")
      printf '%s\n' "${extra[@]: -1}" >>"$TMP/spawn-task.log" ;;
  esac
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" \
    WRK_COMPLETION_INTERVAL_S=3600 WRK_HOSTS_CONFIG="$TMP/no-such-hosts.toml" \
    WRK_FIXTURE_SCENARIO=spawn WRK_FIXTURE_LOG="$log" \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$ROOT" -m "$model" -p "$PROMPT" -w w -l fixture "${extra[@]}"
}

# AC-1: with no REF the consult_only profile is still gate-denied — the
# fixture mirrors the installed scopefuel, which refuses a bare fable
# unconditionally (task #625). The denial reason must reach the caller
# verbatim.
set +e
esc_denied_out="$(spawn_deny "$TMP/herdr-esc-denied.log" fable --job esc-denied --t T1 2>&1)"
esc_denied_rc=$?
set -e
[[ "$esc_denied_rc" -eq 3 ]] ||
  fail "fable without --operator-request must stay gate-denied (rc=$esc_denied_rc): $esc_denied_out"
grep -q 'consult_only' <<<"$esc_denied_out" ||
  fail "fable denial lost the gate's own reason: $esc_denied_out"
[[ ! -e "$TMP/herdr-esc-denied.log" ]] ||
  fail "a gate-denied consult_only spawn reached Herdr"
echo "PASS AC-1 fable-no-ref-still-denied rc=$esc_denied_rc"

# AC-2/AC-6/AC-5/AC-7: a valid REF reaches the gate unchanged, the four fields
# ride gate stdout into the spawn log, and arbiter's quota_pool.record event
# persists them byte-identically.
export TEST_ARBITER_BIN="$ARBITER"
: >"$TMP/scopefuel.log"
rm -f "$TMP/herdr.log"
esc_ok_out="$(spawn_base fable --job esc-ok --t T1 \
  --operator-request hk:doc/research/2026-09-20/example-key --requested-by operator 2>&1)"
grep -q '^OK pane=' <<<"$esc_ok_out" ||
  fail "fable + valid operator request did not spawn: $esc_ok_out"
grep -q -- '--operator-request hk:doc/research/2026-09-20/example-key' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --operator-request: $(cat "$TMP/scopefuel.log")"
grep -q -- '--requested-by operator' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --requested-by: $(cat "$TMP/scopefuel.log")"
# fable's request satisfies consult_only — it overrode no "alternatives
# available" denial, so the gate emits escalation_override=false (task #625).
for field in escalation_override=false \
  operator_request_ref=hk:doc/research/2026-09-20/example-key \
  requested_by=operator ref_resolution=unverified; do
  grep -q "$field" <<<"$esc_ok_out" ||
    fail "spawn log lost gate field $field: $esc_ok_out"
done
gate_ref_resolution="$(tr ' ' '\n' <<<"$esc_ok_out" | sed -n 's/^ref_resolution=//p' | head -1)"
[[ -n "$gate_ref_resolution" ]] || fail "gate stdout had no ref_resolution token: $esc_ok_out"
python3 - "$ARBITER_INBOX_ROOT/esc-ok/events" "$gate_ref_resolution" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
p = record["payload"]
assert p["escalation_override"] == "false", p
assert p["operator_request_ref"] == "hk:doc/research/2026-09-20/example-key", p
assert p["requested_by"] == "operator", p
# AC-7: byte-identical to the token the gate itself printed, not a normalized
# or re-derived value.
assert p["ref_resolution"] == sys.argv[2], p
PY
echo "PASS AC-2/5/6/7 operator-request-passed-fields-persisted: $esc_ok_out"

# hk:task/<int> is the gate's second accepted REF shape.
: >"$TMP/scopefuel.log"
esc_task_out="$(spawn_base fable --job esc-task --t T1 \
  --operator-request hk:task/483 2>&1)"
grep -q '^OK pane=' <<<"$esc_task_out" ||
  fail "fable + hk:task ref did not spawn: $esc_task_out"
grep -q 'operator_request_ref=hk:task/483' <<<"$esc_task_out" ||
  fail "spawn log lost the hk:task ref: $esc_task_out"
grep -q 'requested_by=unknown' <<<"$esc_task_out" ||
  fail "gate's default requested_by=unknown was not preserved: $esc_task_out"
echo "PASS hk-task-ref-accepted-default-requested-by"

# AC-3: a free-text REF is the gate's refusal, not wrk's — rc and reason must
# both propagate.
set +e
esc_badref_out="$(spawn_deny "$TMP/herdr-esc-badref.log" fable --job esc-badref --t T1 \
  --operator-request 'please let me' 2>&1)"
esc_badref_rc=$?
set -e
[[ "$esc_badref_rc" -eq 3 ]] ||
  fail "free-text REF must stay gate-denied (rc=$esc_badref_rc): $esc_badref_out"
grep -q 'operator_request_ref_invalid' <<<"$esc_badref_out" ||
  fail "free-text REF lost the gate's refusal reason: $esc_badref_out"
[[ ! -e "$TMP/herdr-esc-badref.log" ]] ||
  fail "a refused REF reached Herdr"
echo "PASS AC-3 free-text-ref-denied rc=$esc_badref_rc"

# AC-4: the non-escalation profile + REF refusal is also the gate's call.
set +e
esc_opus_out="$(spawn_deny "$TMP/herdr-esc-opus.log" opus --job esc-opus --t T1 \
  --operator-request hk:doc/research/2026-09-20/example-key 2>&1)"
esc_opus_rc=$?
set -e
[[ "$esc_opus_rc" -eq 3 ]] ||
  fail "non-escalation profile + REF must stay gate-denied (rc=$esc_opus_rc): $esc_opus_out"
grep -q 'operator_request_not_applicable' <<<"$esc_opus_out" ||
  fail "non-escalation refusal lost its reason: $esc_opus_out"
[[ ! -e "$TMP/herdr-esc-opus.log" ]] ||
  fail "a not-applicable REF reached Herdr"
echo "PASS AC-4 non-escalation-ref-denied rc=$esc_opus_rc"

# An orphan --requested-by is likewise refused by the gate, not by wrk.
set +e
esc_orphan_out="$(spawn_deny "$TMP/herdr-esc-orphan.log" fable --job esc-orphan --t T1 \
  --requested-by operator 2>&1)"
esc_orphan_rc=$?
set -e
[[ "$esc_orphan_rc" -eq 3 ]] ||
  fail "orphan --requested-by must stay gate-denied (rc=$esc_orphan_rc): $esc_orphan_out"
grep -q 'requested_by_requires_operator_request' <<<"$esc_orphan_out" ||
  fail "orphan requested-by lost its reason: $esc_orphan_out"
[[ ! -e "$TMP/herdr-esc-orphan.log" ]] ||
  fail "an orphan requested-by reached Herdr"
echo "PASS orphan-requested-by-denied rc=$esc_orphan_rc"

# AC-13: a REF smuggling a second audit token ("hk:doc/foo ref_resolution=
# verified") is refused at the gate boundary before it can be emitted raw —
# and even if a forged gate text reached arbiter directly, conflicting values
# are refused rather than first-match-accepted. ref_resolution can never be
# recorded as anything but the gate's own label.
set +e
forge_out="$(spawn_deny "$TMP/herdr-esc-forge.log" fable --job esc-forge --t T1 \
  --operator-request 'hk:doc/foo ref_resolution=verified' 2>&1)"
forge_rc=$?
set -e
[[ "$forge_rc" -eq 3 ]] ||
  fail "a REF carrying an injected audit token must stay gate-denied (rc=$forge_rc): $forge_out"
grep -q 'operator_request_ref_invalid' <<<"$forge_out" ||
  fail "forged REF lost the gate's refusal reason: $forge_out"
[[ ! -e "$TMP/herdr-esc-forge.log" ]] ||
  fail "a forged REF reached Herdr"

forged_gate="$TMP/forged-gate.txt"
printf '%s\n' 'profile=fable pool=claude used_pct=1 class=spend escalation_override=false operator_request_ref=hk:doc/foo ref_resolution=verified requested_by=op ref_resolution=unverified' >"$forged_gate"
"$ARBITER" claim --job esc-forge-direct --agent-label fixture --lane fixture --t T1 >/dev/null
"$ARBITER" claim --job esc-realish --agent-label fixture --lane fixture --t T1 >/dev/null
set +e
"$ARBITER" lease --job esc-forge-direct --kind quota_pool --profile fable \
  --gate-output "$forged_gate" --json >"$TMP/forged-lease.out" 2>"$TMP/forged-lease.err"
forge_arb_rc=$?
set -e
[[ "$forge_arb_rc" -ne 0 ]] ||
  fail "arbiter accepted a gate text whose ref_resolution tokens conflict"
grep -q 'ref_resolution' "$TMP/forged-lease.err" ||
  fail "arbiter's conflict refusal lost its reason: $(cat "$TMP/forged-lease.err")"

# The real gate repeats the same audit values inside its annotation line —
# identical repeats still record (they agree); only a conflict is refused.
realish_gate="$TMP/realish-gate.txt"
printf '%s\n' 'profile=fable pool=claude used_pct=1 class=spend escalation_override=false operator_request_ref=hk:doc/ok requested_by=op ref_resolution=unverified' \
  'fable ok [escalation_override=false operator_request=hk:doc/ok requested_by=op ref_resolution=unverified — annotation]' >"$realish_gate"
"$ARBITER" lease --job esc-realish --kind quota_pool --profile fable \
  --gate-output "$realish_gate" --json >/dev/null ||
  fail "arbiter refused a gate text whose repeated audit values agree"
python3 - "$ARBITER_INBOX_ROOT" <<'PY'
import json, pathlib, sys
forged_ok = seen_realish = False
for path in pathlib.Path(sys.argv[1]).rglob("*.json"):
    event = json.loads(path.read_text())
    if event.get("kind") != "quota_pool.record":
        continue
    value = event["payload"].get("ref_resolution")
    assert value in (None, "unverified"), event
    if event["job_id"] == "esc-forge-direct":
        forged_ok = True
    if event["job_id"] == "esc-realish":
        assert value == "unverified", event
        seen_realish = True
assert not forged_ok, "the refused forged lease still wrote a record"
assert seen_realish, "the agreeing-repeat gate text did not record"
PY
echo "PASS AC-13 forged-ref-cannot-promote-audit-label rc=$forge_rc arb_rc=$forge_arb_rc"

# AC-14: a value-taking option must not swallow the next option token — the
# missing-value error keeps rc=2 and its message at every consume site, and
# the mangled pair never reaches the gate or downstream argv.
: >"$TMP/scopefuel.log"
set +e
swallow_out="$(spawn_deny "$TMP/herdr-esc-swallow.log" fable --job esc-swallow --t T1 \
  --operator-request --requested-by operator 2>&1)"
swallow_rc=$?
set -e
[[ "$swallow_rc" -eq 2 ]] ||
  fail "--operator-request --requested-by must be a missing-value error (rc=$swallow_rc): $swallow_out"
grep -q 'requires a value' <<<"$swallow_out" ||
  fail "missing-value error lost its message: $swallow_out"
[[ ! -e "$TMP/herdr-esc-swallow.log" ]] ||
  fail "a swallowed option token reached Herdr"
! grep -q 'operator-request' "$TMP/scopefuel.log" ||
  fail "a swallowed option token reached the gate: $(cat "$TMP/scopefuel.log")"

# Negative control: a leading-dash value that is not a wrk option still
# parses — "-operator" is a legitimate requested_by and must reach the gate
# verbatim.
: >"$TMP/scopefuel.log"
dashval_out="$(spawn_base fable --job esc-dashval --t T1 \
  --operator-request hk:doc/x --requested-by -operator 2>&1)"
grep -q '^OK pane=' <<<"$dashval_out" ||
  fail "a leading-dash requested_by value was rejected: $dashval_out"
grep -q 'requested_by=-operator' <<<"$dashval_out" ||
  fail "gate did not receive requested_by=-operator verbatim: $dashval_out"
echo "PASS AC-14 option-token-value-not-swallowed rc=$swallow_rc"

# Ordinary spawns carry no operator-request argv and no audit fields — the
# pass-through must be strictly opt-in.
: >"$TMP/scopefuel.log"
plain_out="$(spawn_base codex-terra --job esc-plain --t T1 2>&1)"
grep -q '^OK pane=' <<<"$plain_out"
if grep -q -- 'operator-request\|requested-by' "$TMP/scopefuel.log"; then
  fail "a plain spawn leaked operator-request argv: $(cat "$TMP/scopefuel.log")"
fi
python3 - "$ARBITER_INBOX_ROOT/esc-plain/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
p = record["payload"]
for key in ("escalation_override", "operator_request_ref", "requested_by", "ref_resolution"):
    assert key not in p, p
PY
echo "PASS plain-spawn-carries-no-operator-request"
unset TEST_ARBITER_BIN

# ---------------------------------------------------------------------------
# task #527: --purpose is forwarded verbatim to `scopefuel gate`, the astra
# counsel path defaults it to `architect`, and a role denial (gate rc 5 → wrk
# exit 77) is caller-visibly distinct from a quota denial (rc 3) AND from the
# pre-existing hub quota-policy denial (wrk exit 5).
# ---------------------------------------------------------------------------

grep -q -- '--purpose' <<<"$spawn_help_out" ||
  fail "spawn --help lost --purpose"
run_fail env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
  WRK_FIXTURE_SCENARIO=spawn "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1 --purpose

# The architect counsel path injects --purpose architect on its own: a plain
# `-m codex-astra` spawn must reach the gate with the purpose attached.
: >"$TMP/scopefuel.log"
rm -f "$TMP/herdr.log"
astra_ok_out="$(spawn_base codex-astra --job astra-purpose --t T1 2>&1)"
grep -q '^OK pane=' <<<"$astra_ok_out" ||
  fail "codex-astra counsel spawn did not pass the gate: $astra_ok_out"
grep -q -- '--purpose architect' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --purpose architect: $(cat "$TMP/scopefuel.log")"
grep -q 'model_reasoning_effort=xhigh' "$TMP/herdr.log" ||
  fail "codex-astra default effort drifted from xhigh: $(cat "$TMP/herdr.log")"
echo "PASS 527-astra-counsel-spawn-passes-purpose-architect"

# An explicit allowed purpose still wins over the architect default.
: >"$TMP/scopefuel.log"
rm -f "$TMP/herdr.log"
astra_dir_out="$(spawn_base codex-astra --job astra-purpose-director --t T1 --purpose director 2>&1)"
grep -q '^OK pane=' <<<"$astra_dir_out" ||
  fail "codex-astra --purpose director did not spawn: $astra_dir_out"
grep -q -- '--purpose director' "$TMP/scopefuel.log" ||
  fail "explicit --purpose director was overridden: $(cat "$TMP/scopefuel.log")"
echo "PASS 527-explicit-purpose-overrides-architect-default"

# Role denial: a disallowed purpose is refused by the gate with rc 5, which
# wrk remaps to exit 77 — exit 5 is already quota_hub_policy_gate's
# hub-quota-policy denial, so sharing it would let a caller misread a role
# denial as a quota stop.
set +e
role_denied_out="$(spawn_deny "$TMP/herdr-astra-role.log" codex-astra --job astra-role --t T1 \
  --purpose worker 2>&1)"
role_denied_rc=$?
set -e
[[ "$role_denied_rc" -eq 77 ]] ||
  fail "disallowed purpose must role-deny with wrk rc=77 (rc=$role_denied_rc): $role_denied_out"
grep -q 'role_restricted' <<<"$role_denied_out" ||
  fail "role denial lost the gate's reason: $role_denied_out"
grep -q 'role-denied' <<<"$role_denied_out" ||
  fail "wrk did not label the role denial: $role_denied_out"
[[ ! -e "$TMP/herdr-astra-role.log" ]] ||
  fail "a role-denied astra spawn reached Herdr"
echo "PASS 527-astra-disallowed-purpose-role-denied rc=$role_denied_rc"

# Quota denial: the same profile with an allowed purpose hits the quota path
# and is refused with rc 3 — exactly distinct from the role denial above.
set +e
quota_denied_out="$(WRK_GATE_MODE=3 \
  spawn_deny "$TMP/herdr-astra-quota.log" codex-astra --job astra-quota --t T1 2>&1)"
quota_denied_rc=$?
set -e
[[ "$quota_denied_rc" -eq 3 ]] ||
  fail "quota refusal must keep rc=3 (rc=$quota_denied_rc): $quota_denied_out"
grep -q 'gate blocked' <<<"$quota_denied_out" ||
  fail "quota refusal lost its reason: $quota_denied_out"
if grep -q 'role_restricted\|role-denied' <<<"$quota_denied_out"; then
  fail "quota refusal was mislabeled as a role denial: $quota_denied_out"
fi
[[ "$role_denied_rc" -ne "$quota_denied_rc" ]] ||
  fail "role and quota denials share an exit code — callers cannot tell them apart"
# …and neither may collide with the pre-existing hub quota-policy denial (5).
[[ "$role_denied_rc" -ne 5 && "$quota_denied_rc" -ne 5 ]] ||
  fail "a denial rc collided with hub quota-policy denial (exit 5)"
[[ ! -e "$TMP/herdr-astra-quota.log" ]] ||
  fail "a quota-denied astra spawn reached Herdr"
echo "PASS 527-astra-quota-denial-distinct rc=$quota_denied_rc"

# --purpose is audit metadata for non-astra profiles: it is forwarded but the
# spawn outcome is unchanged.
: >"$TMP/scopefuel.log"
plain_purpose_out="$(spawn_base codex-terra --job plain-purpose --t T1 --purpose builder 2>&1)"
grep -q '^OK pane=' <<<"$plain_purpose_out" ||
  fail "non-astra spawn with --purpose was refused: $plain_purpose_out"
grep -q -- '--purpose builder' "$TMP/scopefuel.log" ||
  fail "gate argv log lost --purpose for non-astra: $(cat "$TMP/scopefuel.log")"
echo "PASS 527-non-astra-purpose-is-audit-only"

# Builder contract: the real arbiter claim artifact remains an envelope while
# wrk's upward-facing events stay flat. owner_lane is always the builder's own
# lane; parent_lane is recorded as information, while panewire resolves parent
# routing from lanes.json. `captain` remains a deprecated input alias only.
export TEST_ARBITER_BIN="$ARBITER"
BUILDER_REPORT="$TMP/builder-report.md"
printf 'builder report terminal line\n' >"$BUILDER_REPORT"
: >"$TMP/herdr.log"
builder_opus_out="$(spawn_base builder-opus --role builder --lane builder-lane --parent parent-lane --job builder-opus-job --t T1 2>&1)"
grep -q 'model=builder-opus' <<<"$builder_opus_out"
grep -q -- '--model opus' "$TMP/herdr.log"
grep -q -- '--effort high' "$TMP/herdr.log"
python3 - "$ARBITER_INBOX_ROOT/builder-opus-job/events/00001-job.claim.json" "$(tail -n 1 "$TMP/spawn-task.log")" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
assert event["kind"] == "job.claim", event
assert event["payload"] == {
    "agent_label": "fixture", "owner_lane": "builder-lane", "parent_lane": "parent-lane",
    "role": "builder", "t_level": "T1", "task_id": int(sys.argv[2]),
}, event
PY
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" escalate builder-opus-job --question 'need parent decision' >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" joined builder-opus-job --pr https://example.invalid/pr/1 --head deadbeef --report "$BUILDER_REPORT" >/dev/null
python3 - "$ARBITER_INBOX_ROOT/builder-opus-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
escalate = next(e for e in events if e["kind"] == "job.escalate")
joined = next(e for e in events if e["kind"] == "job.joined")
assert escalate["owner_lane"] == joined["owner_lane"] == "builder-lane", events
assert escalate["parent_lane"] == joined["parent_lane"] == "parent-lane", events
assert escalate["reason"] == "builder escalation" and escalate["question"] == "need parent decision", escalate
assert joined["reason"] == "builder joined PR" and joined["pr"].endswith("/1") and joined["head"] == "deadbeef", joined
for event in (escalate, joined):
    assert {"pane_id", "report_path", "report_last_line"} <= set(event), event
assert "payload" not in escalate and "payload" not in joined, events
PY
echo "PASS role-builder-spawn-claim-payload-parent"

# The legacy role must hit the same real spawn/claim path, emit one warning,
# and persist only canonical builder in its claim artifact.
: >"$TMP/herdr.log"
captain_alias_err="$TMP/captain-alias.err"
captain_alias_out="$(spawn_base captain-opus --role captain --lane legacy-builder-lane --parent parent-lane --job captain-alias-job --t T1 2>"$captain_alias_err")"
grep -qx 'wrk: warning: --role captain is deprecated; use --role builder' "$captain_alias_err" ||
  fail "legacy captain role must emit its deprecation warning on stderr: $(<"$captain_alias_err")"
[[ "$(grep -c 'deprecated; use --role builder' "$captain_alias_err")" -eq 1 ]] ||
  fail "legacy captain role must emit exactly one deprecation warning: $(<"$captain_alias_err")"
grep -q 'model=captain-opus' <<<"$captain_alias_out"
python3 - "$ARBITER_INBOX_ROOT/captain-alias-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
echo "PASS role-captain-alias-normalizes-to-builder"

# Every builder profile spelling, including both legacy captain spellings,
# must traverse the actual spawn/claim path under canonical --role builder.
builder_profile_index=0
for builder_profile in builder-opus captain-opus builder-sol captain-sol; do
  builder_profile_index=$((builder_profile_index + 1))
  spawn_base "$builder_profile" --role builder --lane "builder-profile-$builder_profile_index" \
    --parent parent-lane --job "builder-profile-$builder_profile_index" --t T1 >/dev/null
done
python3 - "$ARBITER_INBOX_ROOT" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for index in range(1, 5):
    event = json.loads((root / f"builder-profile-{index}" / "events" / "00001-job.claim.json").read_text())
    assert event["payload"]["role"] == "builder", event
PY
echo "PASS builder-accepts-canonical-and-legacy-profile-aliases"

# task #526: --role builder rejects every astra spelling before claim/gate/tab,
# and the refusal names the operator decision. The captain role alias must not
# smuggle captain-astra past the same gate.
builder_reject_astra() {
  local model="$1" tag="$2"; shift 2
  local job="builder-astra-reject-${model}-${tag}" output rc
  set +e
  output="$(spawn_base "$model" "$@" --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]] || fail "--role builder must reject $model (rc=$rc): $output"
  grep -q "rejects astra profile '$model'" <<<"$output" ||
    fail "astra rejection must name the profile: $output"
  grep -q 'hk:doc decision/2026-09-21/astra-allowed-purposes-approved' <<<"$output" ||
    fail "astra rejection must cite the operator decision: $output"
  [[ ! -e "$ARBITER_INBOX_ROOT/$job/events/00001-job.claim.json" ]] ||
    fail "rejected astra builder must not claim $job"
}
builder_reject_astra builder-astra b --role builder --lane astra-b-lane --parent parent-lane
builder_reject_astra codex-astra c --role builder --lane astra-c-lane --parent parent-lane
builder_reject_astra captain-astra k --role builder --lane astra-k-lane --parent parent-lane
builder_reject_astra captain-astra kalias --role captain --lane astra-k-alias-lane --parent parent-lane
echo "PASS role-builder-rejects-astra-spellings"

role_must_fail() {
  local rejected_role="$1" job="$2" output rc
  set +e
  output="$(spawn_base codex-terra --role "$rejected_role" --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  python3 - "$rc" "$rejected_role" "$output" <<'PY'
import sys
assert int(sys.argv[1]) == 2, "unknown --role %r must be a usage error, rc=%s output=%s" % (sys.argv[2], sys.argv[1], sys.argv[3])
PY
  grep -Fqx -- 'wrk: --role accepts only worker or builder (legacy alias: captain)' <<<"$output" ||
    fail "unknown --role '$rejected_role' must hit role validation: $output"
  [[ ! -e "$ARBITER_INBOX_ROOT/$job/events/00001-job.claim.json" ]] || fail "unknown role must not claim $job"
}
role_must_fail admiral role-unknown-admiral
role_must_fail tester role-unknown-tester

role_must_require_value() {
  local job="$1" output rc
  set +e
  output="$(spawn_base codex-terra --role '' --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  python3 - "$rc" "$output" <<'PY'
import sys
assert int(sys.argv[1]) == 2, "empty --role value must be a usage error, rc=%s output=%s" % (sys.argv[1], sys.argv[2])
PY
  grep -Fqx -- 'wrk: --role requires a value' <<<"$output" ||
    fail "empty --role value must hit the value guard: $output"
  [[ ! -e "$ARBITER_INBOX_ROOT/$job/events/00001-job.claim.json" ]] || fail "empty role must not claim $job"
}
role_must_require_value role-unknown-empty
echo "PASS role-unknown-values-are-usage-errors"

expect_exit 2 spawn_base builder-opus --role builder --parent parent-lane --job builder-missing-lane
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --job builder-missing-parent
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --parent parent-lane --owner owner-lane --job builder-owner-conflict
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --parent builder-lane --job builder-self-parent
expect_exit 2 spawn_base builder-opus --role builder --lane director-9 --parent parent-lane --job builder-director-lane
expect_exit 2 spawn_base builder-opus --role builder --lane admiral-9 --parent parent-lane --job builder-admiral-lane
expect_exit 2 spawn_base codex-terra --role worker --lane worker-lane --parent parent-lane --job worker-hierarchy-regression
echo "PASS builder-parent-and-director-lane-guards"

for builder_profile in builder-opus captain-opus builder-sol builder-sol6 captain-sol builder-devin builder-grok builder-kimi builder-luna builder-sonnet \
  builder-opus-low builder-opus-medium builder-sonnet-xhigh builder-sonnet-max builder-sol-high builder-sol-max builder-sol-medium \
  builder-luna-max builder-terra-high builder-terra-xhigh builder-terra-max builder-kimi-high builder-kimi-max \
  builder-grok-low builder-grok-medium builder-grok-xhigh; do
  expect_exit 2 spawn_base "$builder_profile" --role worker --job "worker-reject-${builder_profile}"
done
echo "PASS worker-rejects-all-builder-profile-aliases"

# task #526: the removed astra builder spellings die on the tombstone under the
# default role too — they are gone from ALL_PROFILES and resolve_profile, so no
# role can spawn them.
for removed_profile in builder-astra captain-astra; do
  set +e
  removed_out="$(spawn_base "$removed_profile" --job "removed-${removed_profile}" --t T1 2>&1)"
  removed_rc=$?
  set -e
  [[ "$removed_rc" -eq 2 ]] || fail "removed profile $removed_profile must fail (rc=$removed_rc): $removed_out"
  grep -q "profile '$removed_profile' was removed" <<<"$removed_out" ||
    fail "removed profile $removed_profile must hit the tombstone: $removed_out"
  grep -q 'hk:doc decision/2026-09-21/astra-allowed-purposes-approved' <<<"$removed_out" ||
    fail "removed profile $removed_profile tombstone must cite the decision: $removed_out"
done
expect_exit 2 spawn_base gpt-6-astra --job removed-gpt-6-astra --t T1
echo "PASS removed-astra-builder-spellings-hit-tombstone"

# task #526 AC4: the three builder surfaces must name the same profile set —
# builder/SKILL.md, the `wrk spawn --help` --role paragraph and the --role
# builder accept list. Fixing only one side must turn this RED (that read-order
# dependence is what #505 removed). The literal accept-line pin also makes
# re-adding an astra spelling to the list alone go RED.
accept_line="$(grep -nF 'builder-opus|builder-sol|builder-sol6|builder-devin|builder-devin-medium|builder-devin-max|builder-ds41|builder-ds41-max|builder-grok|builder-kimi|builder-luna|builder-sonnet|builder-opus-low|builder-opus-medium|builder-sonnet-xhigh|builder-sonnet-max|builder-sol-high|builder-sol-max|builder-sol-medium|builder-luna-max|builder-terra-high|builder-terra-xhigh|builder-terra-max|builder-kimi-high|builder-kimi-max|builder-grok-low|builder-grok-medium|builder-grok-xhigh|devin-swe2|devin-swe2-medium|devin-swe2-max|grok|grok-hi|kimi-k3|captain-opus|captain-sol) ;;' "$ROOT/bin/wrk")"
[[ -n "$accept_line" ]] || fail "--role builder accept list drifted or was not found"
[[ "$(wc -l <<<"$accept_line" | tr -d ' ')" == 1 ]] ||
  fail "accept-list pattern is not unique: $accept_line"
# Token pattern covers the whole accept set: builder-*/captain-* spellings plus
# the pilot worker spellings. Bare 'grok' is not extracted (it also matches
# inside builder-grok); grok-hi presence covers it, and the literal accept-line
# pin above guards the list itself. `builder-level` is prose, `captain-NN` is a
# session name in SKILL.md — neither is a profile.
builder_tokens() { grep -oE '(builder|captain)-[a-z0-9-]+|devin-swe2-medium|devin-swe2-max|devin-swe2|grok-hi|kimi-k3' | grep -vxE 'builder-level|captain-[0-9]+' | sort -u; }
accept_set="$(builder_tokens <<<"$accept_line")"
help_block="$(sed -n '/--role worker|builder/,/--lane NAME/p' "$ROOT/bin/wrk")"
help_set="$(builder_tokens <<<"$help_block")"
skill_set="$(builder_tokens <"$ROOT/builder/SKILL.md")"
[[ "$accept_set" == "$help_set" ]] ||
  fail "builder profile set drift (accept vs help): $(diff <(echo "$accept_set") <(echo "$help_set"))"
[[ "$accept_set" == "$skill_set" ]] ||
  fail "builder profile set drift (accept vs SKILL.md): $(diff <(echo "$accept_set") <(echo "$skill_set"))"
if grep -iq 'astra' <<<"$help_block"; then fail "--role help paragraph still names astra"; fi
if grep -iq 'astra' "$ROOT/builder/SKILL.md"; then fail "builder/SKILL.md still names astra"; fi
echo "PASS builder-profile-set-three-source-consistency"

# A legacy/canonical role pair must not create two role-distinct claims for the
# same job: the second real spawn remains an active duplicate and the first
# artifact is canonical builder.
spawn_base builder-opus --role builder --lane collision-lane --parent parent-lane --job role-alias-collision --t T1 >/dev/null
set +e
collision_out="$(spawn_base captain-opus --role captain --lane collision-lane --parent parent-lane --job role-alias-collision --t T1 2>&1)"
collision_rc=$?
set -e
[[ "$collision_rc" -ne 0 ]] || fail "captain alias must not create a second claim for builder's job"
grep -q 'active arbiter job duplicate' <<<"$collision_out" || fail "role alias collision did not fail as an active duplicate: $collision_out"
python3 - "$ARBITER_INBOX_ROOT/role-alias-collision/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
PY
echo "PASS role-builder-captain-alias-collision"

# Reclaim must replace completion metadata, not retain the first claim. First
# reclaim a worker as a builder, then reclaim again under a different parent.
arb claim --job builder-reclaim-job --lane worker-lane --agent-label worker-label --t T1 >/dev/null
arb lease --job builder-reclaim-job --resource builder-reclaim-resource --kind path >/dev/null
arb release --job builder-reclaim-job --resource builder-reclaim-resource --kind path --force >/dev/null
arb claim --job builder-reclaim-job --lane builder-old-lane --agent-label builder-old-label --t T1 \
  --role builder --parent-lane parent-old --reclaim-released >/dev/null
arb event --job builder-reclaim-job --kind job.spawned \
  --payload-json '{"owner_lane":"builder-old-lane","label":"builder-old-label","pane_id":"w1:p1"}' >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" escalate builder-reclaim-job --question 'first reclaim is builder' >/dev/null
arb lease --job builder-reclaim-job --resource builder-reclaim-resource-2 --kind path >/dev/null
arb release --job builder-reclaim-job --resource builder-reclaim-resource-2 --kind path --force >/dev/null
arb claim --job builder-reclaim-job --lane builder-new-lane --agent-label builder-new-label --t T1 \
  --role builder --parent-lane parent-new --reclaim-released >/dev/null
env ARBITER_INBOX_ROOT="$ARBITER_INBOX_ROOT" XDG_DATA_HOME="$XDG_DATA_HOME" \
  "$WRK" joined builder-reclaim-job --pr https://example.invalid/pr/2 --head feedface --report "$BUILDER_REPORT" >/dev/null
python3 - "$ARBITER_INBOX_ROOT/builder-reclaim-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
escalate = next(e for e in events if e["kind"] == "job.escalate")
joined = next(e for e in events if e["kind"] == "job.joined")
assert escalate["owner_lane"] == "builder-old-lane", escalate
assert joined["owner_lane"] == "builder-new-lane", joined
assert joined["parent_lane"] == "parent-new", joined
PY
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log" 2>/dev/null || true
builder_sol_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sol --role builder --lane builder-sol-lane --parent parent-lane --job builder-sol-job --t T1 2>&1)"
grep -q 'model=builder-sol' <<<"$builder_sol_out"
grep -q -- '-m gpt-6.1-sol' "$TMP/herdr.log" ||
  fail "builder-sol must launch gpt-6.1-sol (#1026): $(cat "$TMP/herdr.log")"
# 2026-09-26 (decision 4088 B): a builder seat never takes a max rung —
# builder-sol runs codex-sol at effort high and consults the catalog at high.
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-sol must launch codex-sol at effort high: $(cat "$TMP/herdr.log")"
grep -q 'policy launch codex-sol effort=high' "$TMP/launch.log" ||
  fail "builder-sol must consult the catalog for codex-sol at effort high"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-max" ]]

# ---------------------------------------------------------------------------
# #1026 (2026-09-30 operator decision): the codex-sol family switches to
# gpt-6.1-sol. AC1 — every switched spelling carries -m gpt-6.1-sol at today's
# effort, from the canon when it answers and from PROFILE_MODEL when it cannot.
# ---------------------------------------------------------------------------
sol61_case() {
  local model="$1" effort="$2"; shift 2
  : >"$TMP/herdr.log"
  spawn_base "$model" --job "sol61-$model" --t T1 "$@" >/dev/null
  grep -q -- '-m gpt-6.1-sol' "$TMP/herdr.log" ||
    fail "$model must carry -m gpt-6.1-sol from the canon: $(cat "$TMP/herdr.log")"
  grep -q "model_reasoning_effort=$effort" "$TMP/herdr.log" ||
    fail "$model must keep today's $effort rung: $(cat "$TMP/herdr.log")"
  # Unreachable canon: the literal PROFILE_MODEL must agree with the canon.
  : >"$TMP/herdr.log"
  WRK_LAUNCH_MODE=broken spawn_base "$model" --job "sol61-fb-$model" --t T1 "$@" >/dev/null
  grep -q -- '-m gpt-6.1-sol' "$TMP/herdr.log" ||
    fail "$model fallback must agree with the canon (-m gpt-6.1-sol): $(cat "$TMP/herdr.log")"
  grep -q "model_reasoning_effort=$effort" "$TMP/herdr.log" ||
    fail "$model fallback must keep today's $effort rung: $(cat "$TMP/herdr.log")"
}
sol61_case codex high
sol61_case codex-sol max
sol61_case codex-max max
sol61_case builder-sol high --role builder --lane sol61-builder-lane --parent parent-lane
sol61_case captain-sol high --role builder --lane sol61-captain-lane --parent parent-lane
# The E6 builder rungs are switched spellings too (builder-sol-max is seat-closed
# — its refusal is asserted in the #704 block below).
SCOPEFUEL_E6_ARM=codex-sol@high sol61_case builder-sol-high high --role builder --lane sol61-e6h-lane --parent parent-lane
SCOPEFUEL_E6_ARM=codex-sol@medium sol61_case builder-sol-medium medium --role builder --lane sol61-e6m-lane --parent parent-lane
echo "PASS 1026-AC1-switched-spellings-carry-gpt-6.1-sol"

# AC2 — the rollback spellings pin the literal gpt-6-sol even though the fake
# canon now answers gpt-6.1-sol for codex-sol. codex-sol6 never consults the
# catalog at all (ROB-591 shape, like codex-sol56); builder-sol6 still gets the
# builder-seat consult at codex-sol@high but keeps the literal model id.
# NB: `: >a >b >c` needs a `>` per file — `: >a b c` passes b and c as
# arguments and only truncates a (see the one-file-per-line convention above).
: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
: >"$TMP/launch.log"
sol6_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base codex-sol6 --job codex-sol6-job --t T1 2>&1)"
grep -q 'model=codex-sol6' <<<"$sol6_out"
grep -q -- '-m gpt-6-sol' "$TMP/herdr.log" ||
  fail "codex-sol6 must keep the literal -m gpt-6-sol: $(cat "$TMP/herdr.log")"
grep -q 'model_reasoning_effort=max' "$TMP/herdr.log" ||
  fail "codex-sol6 must keep codex-sol's max default: $(cat "$TMP/herdr.log")"
if grep -q 'gpt-6.1-sol' "$TMP/herdr.log"; then
  fail "codex-sol6 took the canon's model id: $(cat "$TMP/herdr.log")"
fi
[[ ! -s "$TMP/launch.log" ]] ||
  fail "codex-sol6 must not consult the catalog at all: $(cat "$TMP/launch.log")"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-max" ]]

: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
: >"$TMP/launch.log"
bsol6_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sol6 --role builder \
  --lane builder-sol6-lane --parent parent-lane --job builder-sol6-job --t T1 2>&1)"
grep -q 'model=builder-sol6' <<<"$bsol6_out" ||
  fail "builder-sol6 must be admitted under --role builder: $bsol6_out"
grep -q -- '-m gpt-6-sol' "$TMP/herdr.log" ||
  fail "builder-sol6 must keep the literal -m gpt-6-sol (canon serves gpt-6.1-sol): $(cat "$TMP/herdr.log")"
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-sol6 must launch at the builder-seat high rung: $(cat "$TMP/herdr.log")"
if grep -q 'gpt-6.1-sol' "$TMP/herdr.log"; then
  fail "builder-sol6 took the canon's model id: $(cat "$TMP/herdr.log")"
fi
# Exactly one consult, at exactly the graded rung — not a stray codex-sol6
# line, not an unpinned consult that would hand back the max default.
[[ "$(cat "$TMP/launch.log")" == 'policy launch codex-sol effort=high operator=0' ]] ||
  fail "builder-sol6 must still consult the catalog at codex-sol@high: $(cat "$TMP/launch.log")"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-max" ]]
echo "PASS 1026-AC2-rollback-spellings-pin-gpt-6-sol"
# The AC4 assertion-RED mutants live in the mutants section below (mut_wrk /
# expect_red are defined there).

# task #526 AC2: the counsel path must not regress — `wrk spawn -m codex-astra`
# under the default role (the ARCHITECT.md spawn shape, no --role) still
# resolves to gpt-6-astra and still gates as the codex-astra spelling so the
# scopefuel gate remains the single purpose check.
: >"$TMP/herdr.log"
# #527 + #593 combined. The catalog marks codex-astra consult_only and the gate
# role-gates it by declared purpose. These are two spellings of one restriction,
# and requiring both would break the approved counsel path: a bare
# `-m codex-astra` defaults PURPOSE=architect, the gate admits it, and the
# catalog must admit it too. The purpose reaches BOTH — wrk forwards it verbatim
# and scopefuel decides, applying the rule to astra only.
codex_astra_out="$(spawn_base codex-astra --job codex-astra-counsel-job --t T0 2>&1)"
grep -q '^OK pane=' <<<"$codex_astra_out" ||
  fail "the architect counsel spawn must proceed (purpose satisfies consult_only): $codex_astra_out"
grep -q -- '--purpose architect' "$TMP/scopefuel.log" ||
  fail "gate argv lost --purpose architect: $(cat "$TMP/scopefuel.log")"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-astra" ]]
echo "PASS 593-astra-counsel-purpose-satisfies-consult-only"

# A purpose outside #527's list is refused, and the ROLE denial speaks first:
# gate exit 5 surfaces as wrk exit 77, which must not be flattened into the
# catalog refusal's exit 2 — a caller reading 2 would look for a quota problem.
expect_exit 77 spawn_base codex-astra --purpose builder --job astra-bad-purpose --t T0
echo "PASS 593-astra-disallowed-purpose-role-denied-77"

# 🔴 fable is NOT astra: #527 AC⑤ forbids relaxing its consult gate, so a
# purpose must never become a second key to it. Only --operator-request opens
# it. Since #625 the quota gate denies a request-less fable before the held-back
# catalog refusal can speak — the caller-visible reason is the gate's
# consult_only denial, and either way the spawn does not happen.
fable_purpose_out="$(spawn_base fable --purpose architect --job fable-purpose --t T1 2>&1 || true)"
grep -q 'consult_only' <<<"$fable_purpose_out" ||
  fail "a purpose must not satisfy fable's consult_only: $fable_purpose_out"
echo "PASS 593-fable-not-unlocked-by-purpose"

# Mutants: a worker-grade profile, missing parent, and a non-high Opus effort
# must all stop before gate/claim/tab creation.
expect_exit 2 spawn_base codex-terra --role builder --lane builder-lane --parent parent-lane --job builder-terra-mutant
expect_exit 2 spawn_base codex-luna --role builder --lane builder-lane --parent parent-lane --job builder-luna-mutant
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --job builder-parent-mutant
expect_exit 2 spawn_base builder-opus --role builder --lane builder-lane --parent parent-lane --effort max --job builder-effort-mutant
if grep -q 'builder-.*-mutant' "$ARBITER_INBOX_ROOT"/*/events/* 2>/dev/null; then exit 1; fi

# Task 240 builder pilot (operator decision 2026-09-14
# codex-usage-and-builder-profiles §3 devin · §4 grok · §5 kimi): each pilot
# profile reuses its worker profile's kind/argv verbatim, gates as the
# scopefuel-known worker spelling, and rides the same claim path
# (role=builder, parent recorded).
: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_devin_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base builder-devin --role builder --lane builder-devin-lane --parent parent-lane --job builder-devin-job --t T1 2>&1)"
builder_devin_rc=$?
set -e
[[ "$builder_devin_rc" -eq 0 ]] ||
  fail "builder-devin must be admitted under --role builder (rc=$builder_devin_rc): $builder_devin_out"
grep -q 'model=builder-devin' <<<"$builder_devin_out" ||
  fail "builder-devin spawn output lost its model: $builder_devin_out"
builder_devin_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
[[ "$builder_devin_run" == 'pane run w:p1 devin --model swe-2 --permission-mode dangerous --respect-workspace-trust false' ]] ||
  fail "builder-devin must reuse the devin-swe2 worker argv verbatim: $builder_devin_run"
[[ " $builder_devin_run " != *' --effort '* ]] || fail "builder-devin must not gain an effort flag"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "devin-swe2" ]] ||
  fail "builder-devin must gate as the scopefuel-known devin-swe2 spelling"
python3 - "$ARBITER_INBOX_ROOT/builder-devin-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-devin-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
expect_exit 2 spawn_base builder-devin --role builder --lane builder-devin-lane --parent parent-lane --effort high --job builder-devin-effort-mutant
echo "PASS builder-devin pilot profile reuses devin-swe2 kind/argv"

# #635: devin effort is inside the model id, so "builder-devin takes the
# effort too" lands as the swe-2 effort spellings admitted under --role
# builder — same admission mechanism as the devin-swe2 pilot spelling.
for devin_builder_pair in "devin-swe2-medium:swe-2-medium" "devin-swe2-max:swe-2-max"; do
  devin_builder_profile="${devin_builder_pair%%:*}"
  devin_builder_model="${devin_builder_pair#*:}"
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  set +e
  devin_variant_builder_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base "$devin_builder_profile" --role builder --lane "builder-${devin_builder_profile}-lane" --parent parent-lane --job "builder-${devin_builder_profile}-job" --t T1 2>&1)"
  devin_variant_builder_rc=$?
  set -e
  [[ "$devin_variant_builder_rc" -eq 0 ]] ||
    fail "$devin_builder_profile must be admitted under --role builder (rc=$devin_variant_builder_rc): $devin_variant_builder_out"
  grep -q "model=$devin_builder_profile" <<<"$devin_variant_builder_out" ||
    fail "$devin_builder_profile builder spawn output lost its model: $devin_variant_builder_out"
  devin_variant_builder_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
  [[ "$devin_variant_builder_run" == "pane run w:p1 devin --model $devin_builder_model --permission-mode dangerous --respect-workspace-trust false" ]] ||
    fail "$devin_builder_profile builder argv mismatch: $devin_variant_builder_run"
  [[ " $devin_variant_builder_run " != *' --effort '* ]] ||
    fail "$devin_builder_profile builder argv must not gain an effort flag"
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "devin-swe2" ]] ||
    fail "$devin_builder_profile must gate as the scopefuel-known devin-swe2 spelling"
  python3 - "$ARBITER_INBOX_ROOT/builder-${devin_builder_profile}-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
done
echo "PASS devin-swe2 effort spellings admitted under --role builder (#635)"

: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_grok_out="$(spawn_base builder-grok --role builder --lane builder-grok-lane --parent parent-lane --job builder-grok-job --t T1 2>&1)"
builder_grok_rc=$?
set -e
[[ "$builder_grok_rc" -eq 0 ]] ||
  fail "builder-grok must be admitted under --role builder (rc=$builder_grok_rc): $builder_grok_out"
grep -q 'model=builder-grok' <<<"$builder_grok_out" ||
  fail "builder-grok spawn output lost its model: $builder_grok_out"
builder_grok_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_grok_start" == 'agent start fixture --kind grok --pane w:p1 --timeout 30000 -- --always-approve -m grok-4.7 --effort xhigh' ]] ||
  fail "builder-grok must reuse the grok worker argv at effort xhigh: $builder_grok_start"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "grok-hi" ]] ||
  fail "builder-grok must gate as the scopefuel-known grok-hi spelling"
# #737: builder-grok stays the un-pinned spelling — its gate argv carries no
# --effort and no marker is required (the E6 rungs own the rung pins).
if grep -q -- '--effort' "$TMP/scopefuel.log"; then
  fail "builder-grok must not forward a gate --effort: $(cat "$TMP/scopefuel.log")"
fi
python3 - "$ARBITER_INBOX_ROOT/builder-grok-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-grok-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
echo "PASS builder-grok pilot profile reuses grok kind/argv at xhigh"

: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_kimi_out="$(KIMI_CODE_HOME="$TMP/kimi-builder-home" spawn_base builder-kimi --role builder --lane builder-kimi-lane --parent parent-lane --job builder-kimi-job --t T1 2>&1)"
builder_kimi_rc=$?
set -e
[[ "$builder_kimi_rc" -eq 0 ]] ||
  fail "builder-kimi must be admitted under --role builder (rc=$builder_kimi_rc): $builder_kimi_out"
grep -q 'model=builder-kimi' <<<"$builder_kimi_out" ||
  fail "builder-kimi spawn output lost its model: $builder_kimi_out"
builder_kimi_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_kimi_start" == 'agent start fixture --kind kimi --pane w:p1 --timeout 90000 -- --auto -m kimi-code/k3' ]] ||
  fail "builder-kimi must reuse the kimi-k3 worker argv verbatim: $builder_kimi_start"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "kimi-k3" ]] ||
  fail "builder-kimi must gate as the scopefuel-known kimi-k3 spelling"
python3 - "$ARBITER_INBOX_ROOT/builder-kimi-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-kimi-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
( KIMI_CODE_HOME="$TMP/kimi-builder-home" \
  expect_exit 2 spawn_base builder-kimi --role builder --lane builder-kimi-lane --parent parent-lane --effort high --job builder-kimi-effort-mutant )
echo "PASS builder-kimi pilot profile reuses kimi-k3 kind/argv"

# #633 (#594 E3): builder-luna is codex-luna under --role builder, launched at
# the E3 effort (xhigh) and gated as the scopefuel-known codex-luna-max
# spelling like every other luna variant.
: >"$TMP/herdr.log" "$TMP/scopefuel.log"
set +e
builder_luna_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-luna --role builder --lane builder-luna-lane --parent parent-lane --job builder-luna-job --t T1 2>&1)"
builder_luna_rc=$?
set -e
[[ "$builder_luna_rc" -eq 0 ]] ||
  fail "builder-luna must be admitted under --role builder (rc=$builder_luna_rc): $builder_luna_out"
grep -q 'model=builder-luna' <<<"$builder_luna_out" ||
  fail "builder-luna spawn output lost its model: $builder_luna_out"
builder_luna_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_luna_start" == 'agent start fixture --kind codex --pane w:p1 --timeout 120000 -- --yolo -m gpt-6-luna -c model_reasoning_effort=xhigh' ]] ||
  fail "builder-luna must launch the codex-luna argv at effort xhigh: $builder_luna_start"
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == "codex-luna-max" ]] ||
  fail "builder-luna must gate as the scopefuel-known codex-luna-max spelling"
grep -q 'policy launch codex-luna effort=xhigh' "$TMP/launch.log" ||
  fail "builder-luna must consult the catalog for codex-luna at effort xhigh"
python3 - "$ARBITER_INBOX_ROOT/builder-luna-job/events/00001-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "builder-luna-lane", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
# 급 가드 (grade guard): the catalog grades codex-luna per effort
# (medium=B, max=A+) and the E3 sample is rated at xhigh, so any other
# --effort is refused before gate/claim, exactly like builder-opus@high.
expect_exit 2 spawn_base builder-luna --role builder --lane builder-luna-lane --parent parent-lane --effort max --job builder-luna-effort-mutant
expect_exit 2 spawn_base builder-luna --role builder --lane builder-luna-lane --parent parent-lane --effort medium --job builder-luna-effort-low-mutant
expect_exit 2 spawn_base builder-luna --job builder-luna-role-mutant --t T1
echo "PASS builder-luna E3 profile launches codex-luna argv at xhigh"

# ---------------------------------------------------------------------------
# task #921 (operator report 2026-09-29, Sonnet 5.5 experiments E1/E2):
# builder-sonnet is the non-rung Sonnet builder seat — the builder-opus argv
# shape on the sonnet alias, a closed effort set (high|xhigh|max, default
# xhigh), and the seat rule's only named max exception. It is NOT an E6 rung:
# no SCOPEFUEL_E6_ARM, no GATE_EFFORT_PIN — the gate sees bare `-m sonnet`
# (the fixture refuses a sonnet@xhigh/sonnet@max rung gate, so forwarding the
# effort would close the seat). The catalog consult pins the requested rung so
# a bare spawn cannot drift to sonnet's ordinary high default, and the quota
# record carries the canonical launch_profile sonnet@<effort> on pool=claude.
# ---------------------------------------------------------------------------
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log"
set +e
builder_sonnet_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sonnet \
  --role builder --lane builder-sonnet-lane --parent parent-lane \
  --job builder-sonnet-job --t T1 2>&1)"
builder_sonnet_rc=$?
set -e
[[ "$builder_sonnet_rc" -eq 0 ]] ||
  fail "builder-sonnet must be admitted under --role builder (rc=$builder_sonnet_rc): $builder_sonnet_out"
grep -q 'model=builder-sonnet' <<<"$builder_sonnet_out" ||
  fail "builder-sonnet spawn output lost its model: $builder_sonnet_out"
builder_sonnet_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_sonnet_start" == *' -- --model sonnet --dangerously-skip-permissions --effort xhigh' ]] ||
  fail "builder-sonnet must launch the builder-opus argv shape on sonnet at xhigh: $builder_sonnet_start"
grep -q 'policy launch sonnet effort=xhigh' "$TMP/launch.log" ||
  fail "builder-sonnet must consult the catalog for sonnet pinned at xhigh: $(cat "$TMP/launch.log")"
grep -qF 'gate -m sonnet' "$TMP/scopefuel.log" ||
  fail "builder-sonnet must gate as the sonnet spelling: $(cat "$TMP/scopefuel.log")"
if grep -qF 'gate -m sonnet --effort' "$TMP/scopefuel.log"; then
  fail "builder-sonnet is not a rung spelling — the gate must not see --effort: $(cat "$TMP/scopefuel.log")"
fi
[[ "$(tail -n 1 "$TMP/scopefuel.log")" == sonnet ]] ||
  fail "builder-sonnet must gate as sonnet: $(cat "$TMP/scopefuel.log")"
python3 - "$ARBITER_INBOX_ROOT/builder-sonnet-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
claim = next(e for e in events if e["kind"] == "job.claim")
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert claim["payload"]["role"] == "builder", claim
assert claim["payload"]["parent_lane"] == "parent-lane", claim
assert claim["payload"]["owner_lane"] == "builder-sonnet-lane", claim
assert record["payload"]["launch_profile"] == "sonnet@xhigh", record
assert record["payload"]["pool"] == "claude", record
PY

# Explicit rungs restate or move within the closed set; the spawned argv and
# the canonical record track the selected rung.
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log"
builder_sonnet_high_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sonnet \
  --role builder --lane builder-sonnet-high-lane --parent parent-lane \
  --effort high --job builder-sonnet-high-job --t T1 2>&1)"
grep -q 'model=builder-sonnet' <<<"$builder_sonnet_high_out"
builder_sonnet_high_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_sonnet_high_start" == *' -- --model sonnet --dangerously-skip-permissions --effort high' ]] ||
  fail "builder-sonnet --effort high must carry the high rung in argv: $builder_sonnet_high_start"
grep -q 'policy launch sonnet effort=high' "$TMP/launch.log" ||
  fail "builder-sonnet --effort high must pin the catalog consult to high: $(cat "$TMP/launch.log")"
# --effort max: the seat rule's only named exception (E2). Admitted, argv and
# record both carry max.
: >"$TMP/herdr.log" "$TMP/scopefuel.log" "$TMP/launch.log"
builder_sonnet_max_out="$(WRK_LAUNCH_LOG="$TMP/launch.log" spawn_base builder-sonnet \
  --role builder --lane builder-sonnet-max-lane --parent parent-lane \
  --effort max --job builder-sonnet-max-job --t T1 2>&1)"
grep -q 'model=builder-sonnet' <<<"$builder_sonnet_max_out" ||
  fail "builder-sonnet --effort max must be admitted (named seat exception): $builder_sonnet_max_out"
builder_sonnet_max_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$builder_sonnet_max_start" == *' -- --model sonnet --dangerously-skip-permissions --effort max' ]] ||
  fail "builder-sonnet --effort max must carry the max rung in argv: $builder_sonnet_max_start"
grep -q 'policy launch sonnet effort=max' "$TMP/launch.log" ||
  fail "builder-sonnet --effort max must pin the catalog consult to max: $(cat "$TMP/launch.log")"
python3 - "$ARBITER_INBOX_ROOT/builder-sonnet-max-job/events" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert record["payload"]["launch_profile"] == "sonnet@max", record
assert record["payload"]["pool"] == "claude", record
PY

# The effort set is closed: low, medium and ultra die on the builder-sonnet
# arm before resolve_profile (ultra would also die on the seat rule — the arm
# refuses it first, keeping the error on the closed set).
for sonnet_bad_effort in low medium ultra bogus; do
  set +e
  sonnet_bad_out="$(spawn_base builder-sonnet --role builder --lane builder-sonnet-bad-lane \
    --parent parent-lane --effort "$sonnet_bad_effort" --job "builder-sonnet-bad-$sonnet_bad_effort" --t T1 2>&1)"
  sonnet_bad_rc=$?
  set -e
  [[ "$sonnet_bad_rc" -eq 2 ]] ||
    fail "builder-sonnet --effort $sonnet_bad_effort must die rc 2 (rc=$sonnet_bad_rc): $sonnet_bad_out"
  grep -q 'builder-sonnet accepts only --effort high|xhigh|max' <<<"$sonnet_bad_out" ||
    fail "builder-sonnet --effort $sonnet_bad_effort refusal must name the closed set: $sonnet_bad_out"
  [[ ! -e "$ARBITER_INBOX_ROOT/builder-sonnet-bad-$sonnet_bad_effort/events/00001-job.claim.json" ]] ||
    fail "rejected builder-sonnet --effort $sonnet_bad_effort must not claim"
done
echo "PASS 921 builder-sonnet launches sonnet argv at high/xhigh/max, gates bare sonnet, records sonnet@<effort>"

# Assertion-RED mutants: each probes a copy of bin/wrk with exactly one
# behaviour removed. The probe must fail through an assertion (rc 1) — a
# usage error (rc 2+) or a silent pass (rc 0) means the check does not see
# the contract it claims to pin.
expect_red() {
  local label="$1"; shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]] || fail "mutant $label: expected assertion RED (rc 1), got rc $rc"
}
mut_wrk() {  # dst old new — replace exactly one occurrence in a copy of bin/wrk
  python3 - "$WRK" "$1" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:]
text = open(src, encoding="utf-8").read()
assert text.count(old) == 1, "mutant source must occur exactly once: %r" % old
open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  chmod +x "$1"
}
# $1=wrk path, $2=job tag, $3=expected argv tail; extra spawn flags after.
# Returns 0 iff the spawn is admitted and the pane argv ends " -- <tail>".
sonnet_builder_probe() {
  local wrk="$1" tag="$2" want_tail="$3"; shift 3
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  local out start
  out="$(WRK="$wrk" spawn_base builder-sonnet --role builder --lane "mut-$tag-lane" \
    --parent parent-lane --job "mut-$tag" --t T1 "$@" 2>&1)" || return 1
  grep -q 'model=builder-sonnet' <<<"$out" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")" || return 1
  [[ "$start" == *" -- $want_tail" ]] || return 1
}
# $1=wrk path, $2=model, $3=job tag; extra spawn flags after.
# Returns 0 iff the spawn is refused with rc 2.
builder_refused_probe() {
  local wrk="$1" model="$2" tag="$3"; shift 3
  local out rc
  out="$(WRK="$wrk" spawn_base "$model" --role builder --lane "mutr-$tag-lane" \
    --parent parent-lane --job "mutr-$tag" --t T1 "$@" 2>&1)"
  rc=$?
  [[ "$rc" -eq 2 ]] || return 1
}
# $1=wrk path, $2=job tag — 0 iff the quota record is sonnet@xhigh.
sonnet_builder_record_probe() {
  local wrk="$1" tag="$2"
  ARBITER_INBOX_ROOT="$TMP/mut-inbox-$tag" XDG_DATA_HOME="$TMP/mut-xdg-$tag" \
    WRK="$wrk" spawn_base builder-sonnet --role builder --lane "mutq-$tag-lane" \
    --parent parent-lane --job "mutq-$tag" --t T1 >/dev/null 2>&1 || return 1
  python3 - "$TMP/mut-inbox-$tag/mutq-$tag/events" <<'PY' || return 1
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert record["payload"]["launch_profile"] == "sonnet@xhigh", record
PY
}
MUT921="$TMP/mutants-921"
mkdir -p "$MUT921"
# 1. Model mapping: the sonnet alias swapped for opus turns the argv probe RED.
mut_wrk "$MUT921/wrk-model" \
  'builder-sonnet) PROFILE_KIND=claude; DEFAULT_EFFORT=xhigh; EFFORT_SUPPORTED=1; ARGS=(--model sonnet --dangerously-skip-permissions) ;;' \
  'builder-sonnet) PROFILE_KIND=claude; DEFAULT_EFFORT=xhigh; EFFORT_SUPPORTED=1; ARGS=(--model opus --dangerously-skip-permissions) ;;'
# 2. Effort validation: widening the closed set admits --effort low, which the
#    refusal probe must still see die.
mut_wrk "$MUT921/wrk-effortset" \
  'high|xhigh|max) ;;' \
  'high|xhigh|max|low) ;;'
# 3. Effort propagation: dropping the claude --effort append strips the rung
#    from the pane argv entirely.
# shellcheck disable=SC2016 # the pattern is bin/wrk source text, not an expansion
mut_wrk "$MUT921/wrk-effortflag" \
  '        ARGS+=(--effort "$EFFECTIVE_EFFORT")' \
  '        :'
# 4. launch_profile canonicalization: the builder-sonnet arm must record the
#    catalog name sonnet@<effort>, not the launcher spelling.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$MUT921/wrk-launchname" \
  'elif [[ "$MODEL" == builder-sonnet ]]; then' \
  'elif [[ "$MODEL" == builder-sonnet-removed ]]; then'
# 5. Seat exception scope: dropping the model pin opens max for every builder —
#    builder-sol --effort max must still die.
# shellcheck disable=SC2016 # the patterns are bin/wrk source text, not expansions
mut_wrk "$MUT921/wrk-seat" \
  '[[ "$MODEL" == builder-sonnet && "$seat_effort" == max ]]' \
  '[[ "$seat_effort" == max ]]'
# 6. Catalog pin: without the ${EFFORT:-xhigh} pin the consult returns sonnet's
#    ordinary high default and a bare spawn silently launches high.
# shellcheck disable=SC2016 # the pattern is bin/wrk source text, not an expansion
mut_wrk "$MUT921/wrk-catalogpin" \
  'builder-sonnet) CATALOG_PROFILE=sonnet; CATALOG_EFFORT_PIN="${EFFORT:-xhigh}" ;;' \
  'builder-sonnet) CATALOG_PROFILE=sonnet ;;'
expect_red model-swapped-to-opus sonnet_builder_probe "$MUT921/wrk-model" m1 '--model sonnet --dangerously-skip-permissions --effort xhigh'
expect_red effort-set-widened builder_refused_probe "$MUT921/wrk-effortset" builder-sonnet e1 --effort low
expect_red effort-flag-dropped sonnet_builder_probe "$MUT921/wrk-effortflag" e2 '--model sonnet --dangerously-skip-permissions --effort xhigh'
expect_red launch-name-literal sonnet_builder_record_probe "$MUT921/wrk-launchname" q1
expect_red seat-exception-broadened builder_refused_probe "$MUT921/wrk-seat" builder-sol s1 --effort max
expect_red catalog-pin-dropped sonnet_builder_probe "$MUT921/wrk-catalogpin" c1 '--model sonnet --dangerously-skip-permissions --effort xhigh'
echo "PASS 921 mutants assertion-red=6/6 (model map, effort set, effort flag, launch_profile, seat scope, catalog pin)"

# ---------------------------------------------------------------------------
# #1026 AC4 — assertion-RED mutants for the gpt-6.1-sol switch.
# ---------------------------------------------------------------------------
# $1=wrk path; 0 iff a codex-sol6 spawn keeps the literal gpt-6-sol argv.
sol6_literal_probe() {
  local wrk="$1" out start
  : >"$TMP/herdr.log"
  out="$(WRK="$wrk" spawn_base codex-sol6 --job "mut-sol6" --t T1 2>&1)" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")" || return 1
  [[ "$start" == *" -m gpt-6-sol "* ]] || return 1
}
# $1=wrk path; 0 iff an unreachable-canon codex-sol spawn carries gpt-6.1-sol.
sol_fallback_probe() {
  local wrk="$1" out start
  : >"$TMP/herdr.log"
  out="$(WRK="$wrk" WRK_LAUNCH_MODE=broken spawn_base codex-sol --job "mut-solfb" --t T1 2>&1)" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")" || return 1
  [[ "$start" == *" -m gpt-6.1-sol "* ]] || return 1
}
MUT1026="$TMP/mutants-1026"
mkdir -p "$MUT1026"
# M1 — invariant: a rollback spelling never takes the canon's model id.
# Mapping codex-sol6 into resolve_catalog_profile lets the served gpt-6.1-sol
# through; the literal argv probe goes RED.
mut_wrk "$MUT1026/wrk-sol6-canon" \
  'codex-sol|codex-max) CATALOG_PROFILE=codex-sol ;;' \
  'codex-sol|codex-max|codex-sol6) CATALOG_PROFILE=codex-sol ;;'
# M2 — invariant: the fallback table agrees with the canon. A literal left on
# gpt-6-sol silently rolls an unreachable-canon launch back; the fallback
# probe goes RED.
mut_wrk "$MUT1026/wrk-fallback" \
  'codex-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6.1-sol; DEFAULT_EFFORT=max' \
  'codex-sol) PROFILE_KIND=codex; PROFILE_MODEL=gpt-6-sol; DEFAULT_EFFORT=max'
expect_red sol6-takes-canon-model sol6_literal_probe "$MUT1026/wrk-sol6-canon"
expect_red fallback-table-stale sol_fallback_probe "$MUT1026/wrk-fallback"
echo "PASS 1026-AC4-mutants-red"

# #666: the devin effort rungs exist as named builder spellings — same
# unattended argv as the worker variants, gated as devin-swe2 like every
# devin-* profile, and refused without --role builder. builder-ds41[-max] is
# the paid rung admitted per the operator's ds41-builder policy; the ds41
# worker spellings stay worker-only (the refusal loop below pins that).
for devin_builder_pair in "builder-devin-medium:swe-2-medium" "builder-devin-max:swe-2-max" \
  "builder-ds41:deepseek-v4-1-flash-high" "builder-ds41-max:deepseek-v4-1-flash-max"; do
  devin_builder_profile="${devin_builder_pair%%:*}"
  devin_builder_model="${devin_builder_pair#*:}"
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  set +e
  devin_builder_out="$(TEST_FIXTURE_SCENARIO=devin-idle spawn_base "$devin_builder_profile" --role builder --lane "$devin_builder_profile-lane" --parent parent-lane --job "$devin_builder_profile-job" --t T1 2>&1)"
  devin_builder_rc=$?
  set -e
  [[ "$devin_builder_rc" -eq 0 ]] ||
    fail "$devin_builder_profile must be admitted under --role builder (rc=$devin_builder_rc): $devin_builder_out"
  grep -q "model=$devin_builder_profile" <<<"$devin_builder_out" ||
    fail "$devin_builder_profile spawn output lost its model: $devin_builder_out"
  devin_builder_run="$(grep '^pane run w:p1 devin ' "$TMP/herdr.log")"
  [[ "$devin_builder_run" == "pane run w:p1 devin --model $devin_builder_model --permission-mode dangerous --respect-workspace-trust false" ]] ||
    fail "$devin_builder_profile must reuse the worker variant's argv verbatim: $devin_builder_run"
  [[ " $devin_builder_run " != *' --effort '* ]] ||
    fail "$devin_builder_run run argv must not contain effort"
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "devin-swe2" ]] ||
    fail "$devin_builder_profile must gate as the scopefuel-known devin-swe2 spelling"
  python3 - "$ARBITER_INBOX_ROOT/$devin_builder_profile-job/events/00001-job.claim.json" "$devin_builder_profile" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["owner_lane"] == "%s-lane" % sys.argv[2], event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
  expect_exit 2 spawn_base "$devin_builder_profile" --role builder --lane "$devin_builder_profile-lane" --parent parent-lane --effort high --job "$devin_builder_profile-effort-mutant"
  expect_exit 2 spawn_base "$devin_builder_profile" --job "$devin_builder_profile-role-mutant" --t T1
done
echo "PASS #666 devin builder variants reuse the worker argv and need --role builder"

# ---------------------------------------------------------------------------
# #704 (#594 E6) + #737 (decision 4088 grok rungs): per-rung builder spellings
# — the name's last segment IS the pinned rung. Each must launch the exact
# model argv at that effort, ask the gate about <gate profile>@<rung> (wrk
# forwards --effort to the gate for these profiles only), record
# launch_profile=<canonical>@<rung> (#677), and spawn only when
# SCOPEFUEL_E6_ARM names that exact rung. The fixture's escalation model
# still demands --operator-request on its marked rungs (sonnet@xhigh in
# both modes, opus@low in the default mode — see the #740 block below);
# the real installed gate skips the escalation ladder on --effort-named
# rungs (#716), so that demand is fixture-model behaviour, not installed
# behaviour. The kimi pair takes
# its rung from the pinned clone home (kimi has no --effort); the grok rungs
# are plain marker-gated (not escalation).
# Mutants: dropping GATE_EFFORT_PIN, the marker check, the clone-effort check,
# the canonical launch_name, or the gate's --effort forward turns this RED.
# ---------------------------------------------------------------------------

# The kimi rungs read their effort from clone homes (bin/kimi-clone-home
# --effort). Build both from the fixture source the kimi-k3-low block used;
# the clone script itself rejects an unknown effort spelling.
E6_KIMI_HIGH_HOME="$TMP/kimi-e6-high-home"
E6_KIMI_MAX_HOME="$TMP/kimi-e6-max-home"
env KIMI_CODE_SRC="$CLONE_SRC" KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" \
  "$ROOT/bin/kimi-clone-home" --effort high >/dev/null
env KIMI_CODE_SRC="$CLONE_SRC" KIMI_CODE_MAX_HOME="$E6_KIMI_MAX_HOME" \
  "$ROOT/bin/kimi-clone-home" --effort max >/dev/null
grep -q 'effort = "high"' "$E6_KIMI_HIGH_HOME/config.toml" ||
  fail "kimi-clone-home --effort high must pin the clone to high"
grep -q 'effort = "max"' "$E6_KIMI_MAX_HOME/config.toml" ||
  fail "kimi-clone-home --effort max must pin the clone to max"
run_fail env KIMI_CODE_SRC="$CLONE_SRC" "$ROOT/bin/kimi-clone-home" --effort ultra
run_fail env KIMI_CODE_SRC="$CLONE_SRC" "$ROOT/bin/kimi-clone-home" --bogus-flag

# Own inbox: the measurement records stay out of the shared suite inbox.
E6_INBOX="$TMP/inbox-e6"
E6_XDG="$TMP/xdg-e6"

e6_builder_case() {
  local model="$1" gate="$2" rung="$3" argv_tail="$4"; shift 4
  local job="e6-${model}-job" out rc start
  : >"$TMP/herdr.log" "$TMP/scopefuel.log"
  set +e
  out="$(SCOPEFUEL_E6_ARM="$gate@$rung" \
    KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" KIMI_CODE_MAX_HOME="$E6_KIMI_MAX_HOME" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base "$model" --role builder --lane "$model-lane" --parent parent-lane \
    --job "$job" --t T1 "$@" 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "$model must be admitted under --role builder (rc=$rc): $out"
  grep -q "model=$model" <<<"$out" || fail "$model spawn output lost its model: $out"
  start="$(grep '^agent start ' "$TMP/herdr.log")"
  # The exact argv tail pins model + effort — no silent default is possible:
  # for claude/codex the rung is in argv; for kimi it is the clone home.
  [[ "$start" == *" -- $argv_tail" ]] ||
    fail "$model must launch the exact $rung rung argv: $start"
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == "$gate" ]] ||
    fail "$model must gate as $gate: $(cat "$TMP/scopefuel.log")"
  grep -qF "gate -m $gate --effort $rung" "$TMP/scopefuel.log" ||
    fail "$model must ask the gate about the $rung rung: $(cat "$TMP/scopefuel.log")"
  if [[ "$model" == builder-kimi-* ]]; then
    local want_home
    case "$rung" in
      high) want_home="$E6_KIMI_HIGH_HOME" ;;
      max) want_home="$E6_KIMI_MAX_HOME" ;;
    esac
    grep -qF -- "--env KIMI_CODE_HOME=$want_home" "$TMP/herdr.log" ||
      fail "$model must pin KIMI_CODE_HOME to the $rung clone: $(cat "$TMP/herdr.log")"
  fi
  python3 - "$E6_INBOX/$job/events" "$gate@$rung" "$model" <<'PY'
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
claim = next(e for e in events if e["kind"] == "job.claim")
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert claim["payload"]["role"] == "builder", claim
assert claim["payload"]["parent_lane"] == "parent-lane", claim
assert record["payload"]["launch_profile"] == sys.argv[2], (sys.argv[3], record)
PY
}

e6_builder_case builder-opus-low     opus        low    '--model opus --dangerously-skip-permissions --effort low'     --operator-request hk:task/704
e6_builder_case builder-opus-medium  opus        medium '--model opus --dangerously-skip-permissions --effort medium'
e6_builder_case builder-sonnet-xhigh sonnet      xhigh  '--model sonnet --dangerously-skip-permissions --effort xhigh' --operator-request hk:task/704
e6_builder_case builder-sol-high     codex-sol   high   '--yolo -m gpt-6.1-sol -c model_reasoning_effort=high'
# #737: codex-sol@medium joins the sol E6 rungs on the same pin rule.
e6_builder_case builder-sol-medium   codex-sol   medium '--yolo -m gpt-6.1-sol -c model_reasoning_effort=medium'
e6_builder_case builder-terra-high   codex-terra high   '--yolo -m gpt-5.6-terra -c model_reasoning_effort=high'
e6_builder_case builder-terra-xhigh  codex-terra xhigh  '--yolo -m gpt-5.6-terra -c model_reasoning_effort=xhigh'
e6_builder_case builder-kimi-high    kimi-k3     high   '--auto -m kimi-code/k3'
# #737 (decision 4088): the grok E6 rungs — grok-hi@low/medium/xhigh, same
# generic grok argv shape as builder-grok, marker-gated at the pinned rung.
e6_builder_case builder-grok-low     grok-hi     low    '--always-approve -m grok-4.7 --effort low'
e6_builder_case builder-grok-medium  grok-hi     medium '--always-approve -m grok-4.7 --effort medium'
e6_builder_case builder-grok-xhigh   grok-hi     xhigh  '--always-approve -m grok-4.7 --effort xhigh'
echo "PASS 704+737 E6 builder rungs launch exact argv, gate at their rung, record canonical launch_profile"

# 2026-09-26 (decision 4088 B): the five max-rung builder spellings are closed —
# a builder seat never takes a max rung, so the seat rule fires ahead of the
# E6 marker check and refuses even with the exact SCOPEFUEL_E6_ARM armed.
for e6_max_model in builder-sonnet-max builder-sol-max builder-luna-max \
  builder-terra-max builder-kimi-max; do
  case "$e6_max_model" in
    builder-sonnet-max) e6_max_gate=sonnet ;;
    builder-sol-max)    e6_max_gate=codex-sol ;;
    builder-luna-max)   e6_max_gate=codex-luna ;;
    builder-terra-max)  e6_max_gate=codex-terra ;;
    builder-kimi-max)   e6_max_gate=kimi-k3 ;;
  esac
  set +e
  e6_max_out="$(SCOPEFUEL_E6_ARM="$e6_max_gate@max" \
    KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" KIMI_CODE_MAX_HOME="$E6_KIMI_MAX_HOME" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base "$e6_max_model" --role builder --lane "$e6_max_model-lane" --parent parent-lane \
    --job "e6-max-closed-$e6_max_model" --t T1 2>&1)"
  e6_max_rc=$?
  set -e
  [[ "$e6_max_rc" -eq 2 ]] ||
    fail "$e6_max_model with its exact marker must still die rc 2 (rc=$e6_max_rc): $e6_max_out"
  grep -q 'builder seats never take a max rung' <<<"$e6_max_out" ||
    fail "$e6_max_model refusal must name the builder-seat rule: $e6_max_out"
done
# A non-rung spelling cannot sneak max onto a builder seat either: an explicit
# --effort max on builder-sol (default high) dies on the same rule.
set +e
e6_max_out="$(spawn_base builder-sol --role builder --lane e6-effort-max-lane --parent parent-lane \
  --effort max --job e6-builder-sol-effort-max --t T1 2>&1)"
e6_max_rc=$?
set -e
[[ "$e6_max_rc" -eq 2 ]] ||
  fail "builder-sol --effort max must die rc 2 (rc=$e6_max_rc): $e6_max_out"
grep -q 'builder seats never take a max rung' <<<"$e6_max_out" ||
  fail "builder-sol --effort max refusal must name the builder-seat rule: $e6_max_out"
# codex `ultra` is the max tier plus subagents — the seat rule refuses it too.
set +e
e6_max_out="$(spawn_base builder-sol --role builder --lane e6-effort-ultra-lane --parent parent-lane \
  --effort ultra --job e6-builder-sol-effort-ultra --t T1 2>&1)"
e6_max_rc=$?
set -e
[[ "$e6_max_rc" -eq 2 ]] ||
  fail "builder-sol --effort ultra must die rc 2 (rc=$e6_max_rc): $e6_max_out"
grep -q 'builder seats never take a max rung' <<<"$e6_max_out" ||
  fail "builder-sol --effort ultra refusal must name the builder-seat rule: $e6_max_out"
echo "PASS 736 max-rung builder spellings closed by the builder-seat rule"

# #748: the unflagged kimi spellings admitted as builders (builder-kimi,
# kimi-k3) leave EFFECTIVE_EFFORT empty — the seat rule reads the home's
# [thinking] effort instead. A home pinned to max is refused on the same
# seat rule; a home at high is admitted. builder-kimi-max in the loop above
# is refused by the seat rule itself (exact marker armed AND a valid max
# clone still refused), not merely by a missing marker.
for e6_kimi_builder in builder-kimi kimi-k3; do
  set +e
  e6_kmax_out="$(KIMI_CODE_HOME="$E6_KIMI_MAX_HOME" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base "$e6_kimi_builder" --role builder --lane "kmax-$e6_kimi_builder-lane" --parent parent-lane \
    --job "e6-khome-max-$e6_kimi_builder" --t T1 2>&1)"
  e6_kmax_rc=$?
  set -e
  [[ "$e6_kmax_rc" -eq 2 ]] ||
    fail "$e6_kimi_builder on a max-effort kimi home must die rc 2 (rc=$e6_kmax_rc): $e6_kmax_out"
  grep -q 'builder seats never take a max rung' <<<"$e6_kmax_out" ||
    fail "$e6_kimi_builder max-home refusal must name the builder-seat rule: $e6_kmax_out"
done
# A high-effort kimi home stays admitted — same argv as before, no --effort
# anywhere (the CLI has no flag; the rung lives only in the clone config).
: >"$TMP/herdr.log"
set +e
e6_khigh_out="$(KIMI_CODE_HOME="$E6_KIMI_HIGH_HOME" \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane khigh-builder-kimi-lane --parent parent-lane \
  --job e6-khome-high-builder-kimi --t T1 2>&1)"
e6_khigh_rc=$?
set -e
[[ "$e6_khigh_rc" -eq 0 ]] ||
  fail "builder-kimi on a high-effort kimi home must be admitted (rc=$e6_khigh_rc): $e6_khigh_out"
e6_khigh_start="$(grep '^agent start ' "$TMP/herdr.log")"
[[ "$e6_khigh_start" == *' -- --auto -m kimi-code/k3' ]] ||
  fail "builder-kimi on a high home must reuse the kimi-k3 argv verbatim: $e6_khigh_start"
# The seat rule stays builder-scoped: the same max home on a worker spawn is
# unaffected (worker max rungs are a separate reservation, not this rule).
set +e
e6_kworker_out="$(KIMI_CODE_HOME="$E6_KIMI_MAX_HOME" \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base kimi-k3 --job e6-khome-max-worker --t T1 2>&1)"
e6_kworker_rc=$?
set -e
[[ "$e6_kworker_rc" -eq 0 ]] ||
  fail "kimi-k3 worker on a max-effort home must stay admitted (rc=$e6_kworker_rc): $e6_kworker_out"
echo "PASS 748 kimi builder spellings refuse a max-effort home on the seat rule"

# #748r2 (tester round 1): the seat read must resolve what Kimi Code actually
# runs, not just a double-quoted [thinking] effort. Valid TOML literal
# (single-quoted) strings, a missing [thinking] with the spawned model's
# default_effort = "max", and an unsupported [thinking] value falling back to
# a max default all resolve to max — each must die on the seat rule. Mutants
# in test-assignment-defaults.sh pin the resolver itself.
e6_khome() { # build a minimal kimi home: $1=dest, config.toml on stdin
  local dest="$1"
  mkdir -p "$dest/credentials" "$dest/oauth"
  cat >"$dest/config.toml"
  printf 'x\n' >"$dest/credentials/kimi-code.json"
  printf 'x\n' >"$dest/oauth/kimi-code"
  printf 'x\n' >"$dest/device_id"
}
e6_khome "$TMP/kimi-sq-max" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
effort = 'max'
EOF
e6_khome "$TMP/kimi-default-max" <<'EOF'
default_model = "kimi-code/k3"
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "max" ]
default_effort = "max"
EOF
e6_khome "$TMP/kimi-fallback-max" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "max" ]
default_effort = "max"
[thinking]
effort = "xhigh"
EOF
for e6_khome_case in kimi-sq-max kimi-default-max kimi-fallback-max; do
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 2 ]] ||
    fail "builder-kimi on a home resolving to max ($e6_khome_case) must die rc 2 (rc=$e6_krc): $e6_kout"
  grep -q 'builder seats never take a max rung' <<<"$e6_kout" ||
    fail "$e6_khome_case refusal must name the builder-seat rule: $e6_kout"
done
# The same fallback semantics admit when they resolve below max: a
# single-quoted 'high' is a valid TOML rung, and an unsupported 'xhigh'
# request falls back to the model's high default — both launch normally.
e6_khome "$TMP/kimi-sq-high" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
effort = 'high'
EOF
e6_khome "$TMP/kimi-fallback-high" <<'EOF'
[models."kimi-code/k3"]
provider = "managed:kimi-code"
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
effort = "xhigh"
EOF
for e6_khome_case in kimi-sq-high kimi-fallback-high; do
  : >"$TMP/herdr.log"
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 0 ]] ||
    fail "builder-kimi on a home resolving below max ($e6_khome_case) must be admitted (rc=$e6_krc): $e6_kout"
  [[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
    fail "$e6_khome_case must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
done
echo "PASS 748r2 kimi seat rule resolves literal strings and model default_effort fallbacks"

# #748r3 (tester round 2): the resolution must be a real TOML parse — dotted
# keys, inline tables, multiline/escaped strings, indented headers,
# [models."<id>".overrides] entries and comments inside arrays are all
# equivalent spellings Kimi accepts; and KIMI_MODEL_THINKING_EFFORT overrides
# the effort at runtime. [thinking].enabled=false resolves to off_effort.
e6_khome "$TMP/kimi-dotted-thinking" <<'EOF'
thinking.effort = "max"
[models."kimi-code/k3"]
provider = "x"
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
EOF
e6_khome "$TMP/kimi-dotted-model" <<'EOF'
models."kimi-code/k3".provider = "x"
models."kimi-code/k3".support_efforts = [ "low", "high", "max" ]
models."kimi-code/k3".default_effort = "max"
EOF
e6_khome "$TMP/kimi-inline-models" <<'EOF'
models = { "kimi-code/k3" = { support_efforts = [ "low", "high", "max" ], default_effort = "max" } }
EOF
e6_khome "$TMP/kimi-multiline-max" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
effort = """max"""
EOF
# The effort value below is the TOML escape m + ́x: the file literally
# contains "m\u0061x", which a real TOML decode turns into "max".
e6_khome "$TMP/kimi-escaped-max" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
effort = "m\u0061x"
EOF
e6_khome "$TMP/kimi-indented-max" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
  [thinking]
  effort = "max"
EOF
e6_khome "$TMP/kimi-override-max" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[models."kimi-code/k3".overrides]
default_effort = "max"
EOF
e6_khome "$TMP/kimi-comment-support" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ] # "xhigh" intentionally unsupported
default_effort = "max"
[thinking]
effort = "xhigh"
EOF
e6_khome "$TMP/kimi-off-effort-max" <<'EOF'
[models."kimi-code/k3"]
off_effort = "max"
[thinking]
enabled = false
effort = "high"
EOF
# always-thinking also arrives as a capabilities tag or a boolean field —
# enabled=false does not switch the model off in either shape.
e6_khome "$TMP/kimi-at-cap-max" <<'EOF'
[models."kimi-code/k3"]
capabilities = [ "thinking", "always_thinking" ]
default_effort = "high"
[thinking]
enabled = false
effort = "max"
EOF
e6_khome "$TMP/kimi-at-field-max" <<'EOF'
[models."kimi-code/k3"]
always_thinking = true
default_effort = "high"
[thinking]
enabled = false
effort = "max"
EOF
# A malformed config (duplicate keys) can still carry a max line: the python
# parse refuses to decode it, so the awk fallback's scan must stay
# conservative and refuse.
e6_khome "$TMP/kimi-dup-invalid" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
effort = "high"
effort = "max"
EOF
for e6_khome_case in kimi-dotted-thinking kimi-dotted-model kimi-inline-models \
    kimi-multiline-max kimi-escaped-max kimi-indented-max kimi-override-max \
    kimi-comment-support kimi-off-effort-max kimi-at-cap-max kimi-at-field-max \
    kimi-dup-invalid; do
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 2 ]] ||
    fail "builder-kimi on a home resolving to max ($e6_khome_case) must die rc 2 (rc=$e6_krc): $e6_kout"
  grep -q 'builder seats never take a max rung' <<<"$e6_kout" ||
    fail "$e6_khome_case refusal must name the builder-seat rule: $e6_kout"
done
# The env overlay is the rung when exported — even with a below-max home.
e6_khome "$TMP/kimi-env-below" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
effort = "high"
EOF
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-env-below" KIMI_MODEL_THINKING_EFFORT=MAX \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-env-max-lane --parent parent-lane \
  --job e6-kimi-env-max --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi with KIMI_MODEL_THINKING_EFFORT=MAX exported must die rc 2 (rc=$e6_krc): $e6_kout"
grep -q 'builder seats never take a max rung' <<<"$e6_kout" ||
  fail "env-max refusal must name the builder-seat rule: $e6_kout"
# CodeRabbit #153: the env overlay resolves even with no config file (kimi
# applies it with an empty home too) — and must normalize like the real parse
# or MAX bypasses the case-sensitive seat match on spelling alone.
mkdir -p "$TMP/kimi-no-cfg"
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-no-cfg" KIMI_MODEL_THINKING_EFFORT=MAX \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-nocfg-max-lane --parent parent-lane \
  --job e6-kimi-nocfg-max --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi with KIMI_MODEL_THINKING_EFFORT=MAX and no config must die rc 2 (rc=$e6_krc): $e6_kout"
grep -q 'builder seats never take a max rung' <<<"$e6_kout" ||
  fail "no-config env-max refusal must name the builder-seat rule: $e6_kout"
# An env spelling outside the documented rungs is not a rung — fail-open like
# an unparseable config, but only after the bounded check sees it.
: >"$TMP/herdr.log"
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-no-cfg" KIMI_MODEL_THINKING_EFFORT=banana \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-nocfg-bogus-lane --parent parent-lane \
  --job e6-kimi-nocfg-bogus --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 0 ]] ||
  fail "builder-kimi with an undocumented env effort and no config must be admitted (rc=$e6_krc): $e6_kout"
[[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
  fail "bogus-env admission must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
# The pinned rung must come from a real clone file, not the env overlay: a
# missing clone config fails closed even when the env names the pinned rung.
set +e
e6_kout="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$TMP/kimi-no-cfg" \
  KIMI_MODEL_THINKING_EFFORT=high \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi-high --role builder --lane kimi-nocfg-pin-lane --parent parent-lane \
  --job e6-kimi-nocfg-pin --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi-high on a missing clone must die rc 2 even with the pinned rung in env (rc=$e6_krc): $e6_kout"
grep -q 'config.toml missing' <<<"$e6_kout" ||
  fail "missing-clone refusal must name the missing config: $e6_kout"
# The awk fallback (no importable TOML lib) must resolve a quoted-key
# [models."<id>".overrides] header the same way the real parse does — strip
# only the .overrides suffix, never the closing quote.
mkdir -p "$TMP/nopy3bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/nopy3bin/python3"
chmod +x "$TMP/nopy3bin/python3"
e6_khome "$TMP/kimi-awk-override" <<'EOF'
[models."kimi-code/k3".overrides]
default_effort = "max"
EOF
set +e
e6_kout="$(PATH="$TMP/nopy3bin:$PATH" KIMI_CODE_HOME="$TMP/kimi-awk-override" \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-awk-over-lane --parent parent-lane \
  --job e6-kimi-awk-override --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 2 ]] ||
  fail "builder-kimi on an overrides-default max home must die rc 2 via the awk fallback too (rc=$e6_krc): $e6_kout"
grep -q 'builder seats never take a max rung' <<<"$e6_kout" ||
  fail "awk-path overrides-max refusal must name the builder-seat rule: $e6_kout"
# Admitted paths: the env overlay wins over the config (max home + high env),
# and disabled Thinking resolves to off_effort (absent → no rung) even when a
# configured effort or default is max.
e6_khome "$TMP/kimi-env-over-max" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "max"
[thinking]
effort = "max"
EOF
e6_khome "$TMP/kimi-disabled-max" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "high"
[thinking]
enabled = false
effort = "max"
EOF
e6_khome "$TMP/kimi-disabled-defmax" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "max"
[thinking]
enabled = false
EOF
# effort="off" is a valid off spelling — no rung even with a max default;
# an unrecognised env value is not a rung either and falls back to config.
e6_khome "$TMP/kimi-effort-off" <<'EOF'
[models."kimi-code/k3"]
support_efforts = [ "low", "high", "max" ]
default_effort = "max"
[thinking]
effort = "off"
EOF
: >"$TMP/herdr.log"
set +e
e6_kout="$(KIMI_CODE_HOME="$TMP/kimi-env-over-max" KIMI_MODEL_THINKING_EFFORT=high \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-kimi --role builder --lane kimi-env-high-lane --parent parent-lane \
  --job e6-kimi-env-high --t T1 2>&1)"
e6_krc=$?
set -e
[[ "$e6_krc" -eq 0 ]] ||
  fail "KIMI_MODEL_THINKING_EFFORT=high must override a max home and be admitted (rc=$e6_krc): $e6_kout"
[[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
  fail "env-high admission must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
for e6_khome_case in kimi-disabled-max kimi-disabled-defmax kimi-effort-off; do
  : >"$TMP/herdr.log"
  set +e
  e6_kout="$(KIMI_CODE_HOME="$TMP/$e6_khome_case" \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-kimi --role builder --lane "$e6_khome_case-lane" --parent parent-lane \
    --job "e6-$e6_khome_case" --t T1 2>&1)"
  e6_krc=$?
  set -e
  [[ "$e6_krc" -eq 0 ]] ||
    fail "builder-kimi with Thinking disabled ($e6_khome_case) must be admitted (rc=$e6_krc): $e6_kout"
  [[ "$(grep '^agent start ' "$TMP/herdr.log")" == *' -- --auto -m kimi-code/k3' ]] ||
    fail "$e6_khome_case must launch the unchanged kimi-k3 argv: $(cat "$TMP/herdr.log")"
done
echo "PASS 748r3 kimi seat rule resolves real TOML, env overlay, and disabled Thinking"

# Marker mutants: no marker, and a marker naming a different rung, both die on
# wrk's own guard (rc 2, before the gate is asked) — the installed gate then
# fail-closes the unmeasured C rungs a second time for good measure.
# The max-rung spellings are absent here: since 2026-09-26 the builder-seat
# rule refuses them before the marker check (asserted above), so a missing
# marker is no longer the operative refusal for them.
for e6_model in builder-opus-low builder-opus-medium builder-sonnet-xhigh \
  builder-sol-high builder-sol-medium builder-terra-high builder-terra-xhigh \
  builder-kimi-high builder-grok-low builder-grok-medium builder-grok-xhigh; do
  set +e
  e6_missing_out="$(SCOPEFUEL_E6_ARM='' \
    KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" KIMI_CODE_MAX_HOME="$E6_KIMI_MAX_HOME" \
    spawn_base "$e6_model" --role builder --lane "$e6_model-lane" --parent parent-lane \
    --job "e6-nomarker-$e6_model" --t T1 2>&1)"
  e6_missing_rc=$?
  set -e
  [[ "$e6_missing_rc" -eq 2 ]] ||
    fail "$e6_model without SCOPEFUEL_E6_ARM must die rc 2 (rc=$e6_missing_rc): $e6_missing_out"
  grep -q 'E6 measurement profile' <<<"$e6_missing_out" ||
    fail "$e6_model missing-marker refusal must name the marker: $e6_missing_out"
done
set +e
e6_wrong_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high \
  spawn_base builder-sonnet-xhigh --role builder --lane e6-wrong-lane --parent parent-lane \
  --job e6-wrong-marker --t T1 2>&1)"
e6_wrong_rc=$?
set -e
[[ "$e6_wrong_rc" -eq 2 ]] ||
  fail "builder-sonnet-xhigh with a mismatched marker must die rc 2 (rc=$e6_wrong_rc): $e6_wrong_out"
grep -q 'SCOPEFUEL_E6_ARM=sonnet@xhigh' <<<"$e6_wrong_out" ||
  fail "wrong-marker refusal must name the required marker: $e6_wrong_out"
# A correct marker for a different rung of the same gate profile also refuses.
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=kimi-k3@max KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" \
  spawn_base builder-kimi-high --role builder --lane e6-wrong-rung-lane --parent parent-lane \
  --job e6-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-kimi-high with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
# #737: same-profile wrong-rung marker on a grok rung refuses too — a
# grok-hi@medium arm does not open builder-grok-low's grok-hi@low rung.
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=grok-hi@medium \
  spawn_base builder-grok-low --role builder --lane e6-grok-wrong-rung-lane --parent parent-lane \
  --job e6-grok-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-grok-low with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=grok-hi@low' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
# #737 sol rung: the existing codex-sol@high marker must not open
# builder-sol-medium's codex-sol@medium rung.
set +e
e6_rung_out="$(SCOPEFUEL_E6_ARM=codex-sol@high \
  spawn_base builder-sol-medium --role builder --lane e6-sol-wrong-rung-lane --parent parent-lane \
  --job e6-sol-wrong-rung --t T1 2>&1)"
e6_rung_rc=$?
set -e
[[ "$e6_rung_rc" -eq 2 ]] ||
  fail "builder-sol-medium with a same-profile wrong-rung marker must die rc 2 (rc=$e6_rung_rc): $e6_rung_out"
grep -q 'SCOPEFUEL_E6_ARM=codex-sol@medium' <<<"$e6_rung_out" ||
  fail "wrong-rung refusal must name the required marker: $e6_rung_out"
echo "PASS 704+737 E6 marker mutants refuse missing and mismatched SCOPEFUEL_E6_ARM"

# Escalation rung (fixture default escalation model — strict; NOT the
# installed gate, whose #716 rule skips the ladder for --effort rungs): the
# marker alone does not open opus@low — the model gate demands
# --operator-request, and its rc 3 propagates.
set +e
e6_esc_out="$(SCOPEFUEL_E6_ARM=opus@low \
  spawn_base builder-opus-low --role builder --lane e6-esc-lane --parent parent-lane \
  --job e6-esc-noopreq --t T1 2>&1)"
e6_esc_rc=$?
set -e
[[ "$e6_esc_rc" -eq 3 ]] ||
  fail "opus@low without --operator-request must hit the gate escalation refusal (rc=$e6_esc_rc): $e6_esc_out"
grep -q 'escalation' <<<"$e6_esc_out" ||
  fail "opus@low refusal must be the escalation denial: $e6_esc_out"
echo "PASS 704 E6 escalation rung still requires --operator-request (fixture escalation model)"

# ---------------------------------------------------------------------------
# #740 (scopefuel #738 / b5b0ad2): post-#738 opus@low is an ordinary S rung —
# builder-opus-low must spawn on its SCOPEFUEL_E6_ARM marker alone (wrk
# neither adds nor demands --operator-request), and a caller-supplied REF is
# forwarded verbatim into the gate's own operator_request_not_applicable
# rc 3. sonnet@xhigh stays escalation-gated across the fixture's two modes
# (model claim — real #716+ gates skip the ladder on --effort rungs for it
# too; whether the gate should enforce it is a separate decision). The knob
# WRK_GATE_738=1 selects the post-#738 gate (matches real b5b0ad2 for
# opus@low); the default is a synthetic strict escalation model — the real
# installed gate does NOT demand a REF on --effort-named rungs (scopefuel
# #716), so the default exercises refusal propagation, not installed
# behaviour. Mutants: wrk auto-adding --operator-request for opus@low, wrk
# locally demanding it, or the fixture keeping opus@low escalation-marked
# under WRK_GATE_738 all turn this block RED.
# ---------------------------------------------------------------------------

# Help text: the escalation-gated list must name sonnet@xhigh only — a stale
# opus@low entry teaches callers to pass a REF the post-#738 gate refuses.
grep -qF 'marks escalation (sonnet@xhigh)' <<<"$spawn_help_out" ||
  fail "spawn --help lost the sonnet@xhigh escalation note"
if grep -qF 'opus@low, sonnet@xhigh' <<<"$spawn_help_out"; then
  fail "spawn --help still lists opus@low as escalation-gated"
fi

# Returns 0 iff a bare builder-opus-low spawn is admitted on its marker alone:
# exact rung argv, gate asked about opus@low with no --operator-request in the
# argv, and the quota record carries the canonical launch_profile with no REF
# fields. Returns nonzero on ANY failed check (assertion failure, not exit) so
# the same predicate can be run against both gate worlds below. The body is a
# subshell on purpose: the internal set +e/set -e toggles and the failing
# return must not leak into the caller — a `{ }` body would re-enable -e
# globally and the mutant call below would kill the suite instead of
# producing a captured nonzero rc.
e6_opus_low_marker_only() (
  local job="$1" out rc start
  # NOTE: each file needs its own redirection — `: >a b` would leave
  # scopefuel.log untruncated and the no-REF assertion below would trip on
  # stale --operator-request lines from the earlier escalation cases.
  : >"$TMP/herdr.log"
  : >"$TMP/scopefuel.log"
  set +e
  out="$(SCOPEFUEL_E6_ARM=opus@low \
    ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
    spawn_base builder-opus-low --role builder --lane e6-740-lane --parent parent-lane \
    --job "$job" --t T1 2>&1)"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || return 1
  grep -q 'model=builder-opus-low' <<<"$out" || return 1
  start="$(grep '^agent start ' "$TMP/herdr.log")"
  [[ "$start" == *' -- --model opus --dangerously-skip-permissions --effort low' ]] || return 1
  [[ "$(tail -n 1 "$TMP/scopefuel.log")" == opus ]] || return 1
  grep -qF 'gate -m opus --effort low' "$TMP/scopefuel.log" || return 1
  ! grep -q -- '--operator-request' "$TMP/scopefuel.log" || return 1
  ! grep -q -- '--requested-by' "$TMP/scopefuel.log" || return 1
  python3 - "$E6_INBOX/$job/events" <<'PY' || return 1
import json, pathlib, sys
events = [json.loads(p.read_text()) for p in pathlib.Path(sys.argv[1]).glob("*.json")]
claim = next(e for e in events if e["kind"] == "job.claim")
record = next(e for e in events if e["kind"] == "quota_pool.record")
assert claim["payload"]["role"] == "builder", claim
p = record["payload"]
assert p["launch_profile"] == "opus@low", p
for key in ("escalation_override", "operator_request_ref", "requested_by", "ref_resolution"):
    assert key not in p, p
PY
)

# Post-#738 gate: marker-only spawn is admitted with a REF-free gate argv.
WRK_GATE_738=1 e6_opus_low_marker_only e6-740-marker-only ||
  fail "post-#738 gate must admit builder-opus-low on its marker alone"
echo "PASS 740 post-738 builder-opus-low spawns on its E6 marker alone"

# Assertion-RED mutant: the identical assertions under the escalation-model
# gate MUST fail — the marker-only spawn is model-refused there
# (escalation), so a GREEN here would prove the predicate cannot tell the
# two gate behaviours apart (and a wrk that auto-added the REF would fail
# the no-REF check under WRK_GATE_738 the same way).
set +e
e6_opus_low_marker_only e6-740-mutant
e6_mutant_rc=$?
set -e
[[ "$e6_mutant_rc" -ne 0 ]] ||
  fail "assertion mutant: marker-only assertions passed under the escalation-model gate — they do not discriminate"
echo "PASS 740 marker-only assertions go RED on the escalation-model gate (mutant)"

# Post-#738 gate: a caller-supplied REF on opus@low is still forwarded
# verbatim and dies on the gate's own not_applicable refusal — wrk never
# pre-judges applicability.
set +e
e6_738_ref_out="$(SCOPEFUEL_E6_ARM=opus@low WRK_GATE_738=1 \
  spawn_deny "$TMP/herdr-740-ref.log" builder-opus-low --role builder --lane e6-740ref-lane --parent parent-lane \
  --job e6-740-ref --t T1 --operator-request hk:task/740 2>&1)"
e6_738_ref_rc=$?
set -e
[[ "$e6_738_ref_rc" -eq 3 ]] ||
  fail "post-#738 opus@low + REF must hit the gate not_applicable refusal (rc=$e6_738_ref_rc): $e6_738_ref_out"
grep -q 'operator_request_not_applicable' <<<"$e6_738_ref_out" ||
  fail "post-#738 REF refusal lost its reason: $e6_738_ref_out"
grep -qF -- '--operator-request hk:task/740' "$TMP/scopefuel.log" ||
  fail "the REF must still reach the gate verbatim: $(cat "$TMP/scopefuel.log")"
[[ ! -e "$TMP/herdr-740-ref.log" ]] ||
  fail "a not_applicable REF reached Herdr"
echo "PASS 740 post-738 opus@low + REF is gate-refused not_applicable, verbatim forward"

# sonnet@xhigh stays escalation-gated in BOTH fixture modes: marker alone is
# refused (rc 3), marker + REF is admitted.
set +e
e6_sx_def_out="$(SCOPEFUEL_E6_ARM=sonnet@xhigh \
  spawn_deny "$TMP/herdr-740-sx-def.log" builder-sonnet-xhigh --role builder --lane e6-sxdef-lane --parent parent-lane \
  --job e6-740-sx-def --t T1 2>&1)"
e6_sx_def_rc=$?
set -e
[[ "$e6_sx_def_rc" -eq 3 ]] ||
  fail "escalation-model sonnet@xhigh without REF must stay escalation-denied (rc=$e6_sx_def_rc): $e6_sx_def_out"
grep -q 'escalation' <<<"$e6_sx_def_out" ||
  fail "escalation-model sonnet@xhigh refusal must stay the escalation denial: $e6_sx_def_out"
[[ ! -e "$TMP/herdr-740-sx-def.log" ]] ||
  fail "a denied sonnet@xhigh spawn reached Herdr"
set +e
e6_738_sx_out="$(SCOPEFUEL_E6_ARM=sonnet@xhigh WRK_GATE_738=1 \
  spawn_deny "$TMP/herdr-740-sx.log" builder-sonnet-xhigh --role builder --lane e6-740sx-lane --parent parent-lane \
  --job e6-740-sx-noref --t T1 2>&1)"
e6_738_sx_rc=$?
set -e
[[ "$e6_738_sx_rc" -eq 3 ]] ||
  fail "post-#738 sonnet@xhigh without REF must stay escalation-denied (rc=$e6_738_sx_rc): $e6_738_sx_out"
grep -q 'escalation' <<<"$e6_738_sx_out" ||
  fail "sonnet@xhigh refusal must stay the escalation denial: $e6_738_sx_out"
[[ ! -e "$TMP/herdr-740-sx.log" ]] ||
  fail "a denied sonnet@xhigh spawn reached Herdr"
: >"$TMP/herdr.log"
: >"$TMP/scopefuel.log"
set +e
e6_738_sxok_out="$(SCOPEFUEL_E6_ARM=sonnet@xhigh WRK_GATE_738=1 \
  ARBITER_INBOX_ROOT="$E6_INBOX" XDG_DATA_HOME="$E6_XDG" \
  spawn_base builder-sonnet-xhigh --role builder --lane e6-740sxok-lane --parent parent-lane \
  --job e6-740-sx-ok --t T1 --operator-request hk:task/740 2>&1)"
e6_738_sxok_rc=$?
set -e
[[ "$e6_738_sxok_rc" -eq 0 ]] ||
  fail "post-#738 sonnet@xhigh + REF spawn refused (rc=$e6_738_sxok_rc): $e6_738_sxok_out"
grep -q '^OK pane=' <<<"$e6_738_sxok_out" ||
  fail "post-#738 sonnet@xhigh + REF did not spawn: $e6_738_sxok_out"
grep -qF 'gate -m sonnet --effort xhigh --operator-request hk:task/740' "$TMP/scopefuel.log" ||
  fail "sonnet@xhigh REF must reach the gate verbatim: $(cat "$TMP/scopefuel.log")"
grep -q 'escalation_override=true' <<<"$e6_738_sxok_out" ||
  fail "sonnet@xhigh must keep escalation_override=true: $e6_738_sxok_out"
echo "PASS 740 sonnet@xhigh stays escalation-gated under both fixture modes"

# Effort mutants: off-rung --effort is refused on the pin; the same rung
# spelled out is accepted; kimi refuses --effort outright (no CLI flag); a
# clone home at the wrong effort — or missing entirely — fails closed.
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=opus@medium \
  spawn_base builder-opus-low --role builder --lane e6-eff-lane --parent parent-lane \
  --effort medium --operator-request hk:task/704 --job e6-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-opus-low --effort medium must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=codex-terra@max \
  spawn_base builder-terra-high --role builder --lane e6-eff2-lane --parent parent-lane \
  --effort max --job e6-eff2-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-terra-high --effort max must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=codex-sol@medium \
  spawn_base builder-sol-medium --role builder --lane e6-sol-eff-lane --parent parent-lane \
  --effort high --job e6-sol-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-sol-medium --effort high must die on the pin (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_eff_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$E6_KIMI_HIGH_HOME" \
  spawn_base builder-kimi-high --role builder --lane e6-kimi-eff-lane --parent parent-lane \
  --effort high --job e6-kimi-eff-mutant --t T1 2>&1)"
e6_eff_rc=$?
set -e
[[ "$e6_eff_rc" -eq 2 ]] ||
  fail "builder-kimi-high --effort must die rc 2 — kimi has no CLI effort flag (rc=$e6_eff_rc): $e6_eff_out"
set +e
e6_clone_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$E6_KIMI_MAX_HOME" \
  spawn_base builder-kimi-high --role builder --lane e6-clone-lane --parent parent-lane \
  --job e6-clone-mutant --t T1 2>&1)"
e6_clone_rc=$?
set -e
[[ "$e6_clone_rc" -eq 2 ]] ||
  fail "builder-kimi-high on a max clone must die rc 2 (rc=$e6_clone_rc): $e6_clone_out"
grep -q 'kimi-clone-home --effort high' <<<"$e6_clone_out" ||
  fail "clone-mismatch refusal must name the fix: $e6_clone_out"
set +e
e6_clone_out="$(SCOPEFUEL_E6_ARM=kimi-k3@high KIMI_CODE_HIGH_HOME="$TMP/kimi-no-such-home" \
  spawn_base builder-kimi-high --role builder --lane e6-clone2-lane --parent parent-lane \
  --job e6-clone-missing --t T1 2>&1)"
e6_clone_rc=$?
set -e
[[ "$e6_clone_rc" -eq 2 ]] ||
  fail "builder-kimi-high with a missing clone home must die rc 2 (rc=$e6_clone_rc): $e6_clone_out"
# The pinned rung spelled out explicitly is allowed.
: >"$TMP/herdr.log"
set +e
e6_same_out="$(SCOPEFUEL_E6_ARM=codex-terra@high \
  spawn_base builder-terra-high --role builder --lane e6-same-lane --parent parent-lane \
  --effort high --job e6-same-effort --t T1 2>&1)"
e6_same_rc=$?
set -e
[[ "$e6_same_rc" -eq 0 ]] ||
  fail "builder-terra-high --effort high (the pinned rung) must be admitted (rc=$e6_same_rc): $e6_same_out"
grep -q 'model_reasoning_effort=high' "$TMP/herdr.log" ||
  fail "builder-terra-high --effort high must keep the pinned rung: $e6_same_out"
# Role/hierarchy mutants for the new spellings.
set +e
e6_hier_out="$(SCOPEFUEL_E6_ARM=codex-sol@high \
  spawn_base builder-sol-high --role builder --lane e6-noparent-lane --job e6-noparent --t T1 2>&1)"
e6_hier_rc=$?
set -e
[[ "$e6_hier_rc" -eq 2 ]] ||
  fail "builder-sol-high --role builder without --parent must die rc 2 (rc=$e6_hier_rc): $e6_hier_out"
set +e
e6_hier_out="$(SCOPEFUEL_E6_ARM=sonnet@max \
  spawn_base builder-sonnet-max --job e6-worker-role --t T1 2>&1)"
e6_hier_rc=$?
set -e
[[ "$e6_hier_rc" -eq 2 ]] ||
  fail "builder-sonnet-max without --role builder must die rc 2 (rc=$e6_hier_rc): $e6_hier_out"
echo "PASS 704 E6 effort pin, clone-home, and hierarchy mutants"
for pilot_alias in grok grok-hi kimi-k3; do
  set +e
  pilot_alias_out="$(KIMI_CODE_HOME="$TMP/kimi-builder-home" spawn_base "$pilot_alias" --role builder --lane "pilot-${pilot_alias}-lane" --parent parent-lane --job "pilot-${pilot_alias}-job" --t T1 2>&1)"
  pilot_alias_rc=$?
  set -e
  [[ "$pilot_alias_rc" -eq 0 ]] ||
    fail "pilot worker spelling '$pilot_alias' must be admitted under --role builder: $pilot_alias_out"
  grep -q "model=$pilot_alias" <<<"$pilot_alias_out" ||
    fail "pilot worker spelling '$pilot_alias' spawn output lost its model: $pilot_alias_out"
  python3 - "$ARBITER_INBOX_ROOT/pilot-${pilot_alias}-job/events/00001-job.claim.json" "$pilot_alias" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
assert event["payload"]["owner_lane"] == "pilot-%s-lane" % sys.argv[2], event
PY
done
echo "PASS builder-pilot-admits-worker-spellings"

# Profiles outside the allowlist are still refused before the gate, and the
# refusal enumerates the builder profiles by name plus the worker-only
# devin model variants (task 281, #635 ds41-max, #666 builder spellings —
# the ds41 worker spellings stay refused under --role builder).
for rejected in codex-terra codex-luna oc-solar4 devin-ds41 devin-ds41-max; do
  set +e
  rejected_out="$(spawn_base "$rejected" --role builder --lane builder-lane --parent parent-lane --job "builder-reject-$rejected" --t T1 2>&1)"
  rejected_rc=$?
  set -e
  [[ "$rejected_rc" -eq 2 ]] ||
    fail "--role builder must still reject $rejected with exit 2, got $rejected_rc: $rejected_out"
  for named in builder-devin builder-devin-medium builder-devin-max builder-ds41 builder-ds41-max builder-grok builder-kimi builder-luna builder-sonnet devin-glm52 devin-swe17 devin-ds41 devin-ds41-max; do
    grep -q "$named" <<<"$rejected_out" ||
      fail "the --role builder refusal must list $named: $rejected_out"
  done
done
echo "PASS builder-pilot-allowlist-rejects-outsiders-with-named-message"

# R19a keeps the historical captain payload as an inbox-consumer regression
# input, while the new builder claim must be the exact bytes emitted by the
# production arbiter writer (never a hand-maintained lookalike).
PANEVIRE_FIXTURE="$ROOT/tests/fixtures/panewire-r19a"
PANEVIRE_OUTPUT="$TMP/panewire-r19a-output"
"$PANEVIRE_FIXTURE/regen.sh" "$PANEVIRE_OUTPUT"
for fixture in "$PANEVIRE_FIXTURE"/*.json; do
  cmp "$fixture" "$PANEVIRE_OUTPUT/$(basename "$fixture")"
done
[[ "$(find "$PANEVIRE_OUTPUT" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')" -eq 5 ]]
python3 - "$PANEVIRE_OUTPUT/00005-builder-job.claim.json" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
assert event["payload"]["role"] == "builder", event
assert event["payload"]["parent_lane"] == "parent-lane", event
PY
unset TEST_ARBITER_BIN
echo "PASS builder profiles, own-lane escalation/JOIN, reclaim metadata, fixture bytes, and fail-closed mutants"

# ⑤ a broken state db is a quota-record failure: warn and still spawn.
rm -f "$TMP/herdr.log"
export TEST_ARBITER_BIN="$ARBITER"
printf 'not a database\n' >"$TMP/xdg/arbiter/state.db"
rm -f "$TMP/xdg/arbiter/state.db-wal" "$TMP/xdg/arbiter/state.db-shm"
schema_failed_out="$(spawn_base grok --job arb-broken --t T1 2>&1)"
grep -q 'arbiter quota-pool claim failed' <<<"$schema_failed_out"
grep -q 'continuing spawn' <<<"$schema_failed_out"
[[ -e "$TMP/herdr.log" ]]
rm -rf "$TMP/xdg/arbiter"
unset TEST_ARBITER_BIN

# ROB-1198 §③: an unclassified job is refused outright — no default T, and the
# refusal happens before the gate, the claim and the spawn.
spawn_untyped() {
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="${TEST_ARBITER_BIN:-$TMP/absent-arbiter}" WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture "$@"
}
rm -f "$TMP/herdr.log" "$TMP/scopefuel.log"
export TEST_ARBITER_BIN="$ARBITER"
untyped_out="$(spawn_untyped "$@" 2>&1 || true)"
grep -q 'NEEDS_CLASSIFICATION' <<<"$untyped_out"
if grep -q '^OK ' <<<"$untyped_out"; then exit 1; fi
expect_exit 2 spawn_untyped
[[ ! -e "$TMP/herdr.log" ]]                      # nothing spawned
[[ ! -e "$TMP/scopefuel.log" ]]                  # gate not even consulted
expect_exit 2 spawn_untyped --t T9
expect_exit 2 spawn_untyped --t ""
[[ ! -e "$TMP/herdr.log" ]]
[[ ! -e "$TMP/scopefuel.log" ]]
# A classified job goes through, and the classification is what gets recorded.
expect_exit 0 spawn_untyped --job arb-typed --t T3
arb status --job arb-typed --json |
  python3 -c 'import json,sys; j=json.load(sys.stdin)["jobs"]; assert j[0]["t_level"]=="T3", j'
arb status --json |
  python3 -c 'import json,sys; assert not [j for j in json.load(sys.stdin)["jobs"] if j["job"]=="fixture"], "an unclassified job was claimed"'
unset TEST_ARBITER_BIN

# Canonical checkout off default branch → warn on stderr, spawn still proceeds (exit 0).
# Worktree / on-default / unresolved origin/HEAD → silent. No hard-coded "main".
canon_guard_spawn() {
  local cwd="$1"
  env HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" WRK_NO_SLEEP=1 \
    ARBITER_BIN="$TMP/absent-arbiter" WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/herdr.log" WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" \
    "$WRK" spawn -c "$cwd" -m codex-terra -p "$PROMPT" -w w -l fixture --t T1
}
setup_temp_repo() {
  # $1 = dest dir. Creates a bare origin + clone with origin/HEAD = master (not main)
  # so the guard cannot be cheating with a hard-coded "main" string compare.
  local dest="$1" bare="$TMP/canon-guard-origin.git"
  rm -rf "$bare" "$dest"
  mkdir -p "$dest"
  git init -q -b master --bare "$bare"
  git -C "$dest" init -q -b master
  git -C "$dest" config user.email "wrk-test@example.com"
  git -C "$dest" config user.name "wrk-test"
  printf 'x\n' >"$dest/README"
  git -C "$dest" add README
  git -C "$dest" commit -q -m init
  git -C "$dest" remote add origin "$bare"
  git -C "$dest" push -q -u origin master
  git -C "$dest" remote set-head origin master
}
CG_REPO="$TMP/canon-guard-repo"
setup_temp_repo "$CG_REPO"
# 1) canonical off default → warning + spawn continues
git -C "$CG_REPO" switch -q -c feature/off-default
: >"$TMP/herdr.log"
set +e
off_out="$(canon_guard_spawn "$CG_REPO" 2>&1)"
off_rc=$?
set -e
[[ "$off_rc" -eq 0 ]]
grep -q 'canonical checkout is not on default branch' <<<"$off_out"
grep -q "path=$CG_REPO" <<<"$off_out"
grep -q 'current=feature/off-default' <<<"$off_out"
grep -q 'default=master' <<<"$off_out"
grep -q "recover: git -C" <<<"$off_out"
grep -q 'switch' <<<"$off_out"
grep -q '^OK ' <<<"$off_out"
# 2) canonical on default → no canonical warning
git -C "$CG_REPO" switch -q master
: >"$TMP/herdr.log"
on_out="$(canon_guard_spawn "$CG_REPO" 2>&1)"
if grep -q 'canonical checkout is not on default branch' <<<"$on_out"; then exit 1; fi
grep -q '^OK ' <<<"$on_out"
# 3) linked worktree off default at worktree path → silent (path is not canonical)
CG_WT="$TMP/canon-guard-wt"
rm -rf "$CG_WT"
git -C "$CG_REPO" worktree add -q -b feature/wt-branch "$CG_WT"
: >"$TMP/herdr.log"
wt_out="$(canon_guard_spawn "$CG_WT" 2>&1)"
if grep -q 'canonical checkout is not on default branch' <<<"$wt_out"; then exit 1; fi
grep -q '^OK ' <<<"$wt_out"
# 4) origin/HEAD missing → quiet skip even if off default (no false positive)
git -C "$CG_REPO" switch -q -c feature/no-origin-head
git -C "$CG_REPO" remote remove origin
: >"$TMP/herdr.log"
skip_out="$(canon_guard_spawn "$CG_REPO" 2>&1)"
if grep -q 'canonical checkout is not on default branch' <<<"$skip_out"; then exit 1; fi
grep -q '^OK ' <<<"$skip_out"
# Guard must not hard-code main: the warn path used default=master above.
if grep -q "default=main" <<<"$off_out"; then exit 1; fi
git -C "$CG_REPO" worktree remove -f "$CG_WT" 2>/dev/null || rm -rf "$CG_WT"
echo "PASS canonical-checkout-guard"

# `wrk done` must consume artifacts produced by the real arbiter, not a
# hand-written fixture. Exercise both arbiter's default root and its explicit
# ARBITER_INBOX_ROOT override; completed stays a flat record with top-level epoch.
real_done_case() (
  local mode="$1" job="wrk-done-$1" case_home="$TMP/home-$1" jobs_root report
  export HOME="$case_home" XDG_DATA_HOME="$TMP/xdg-$1"
  mkdir -p "$HOME"
  case "$mode" in
    default)
      unset ARBITER_INBOX_ROOT
      jobs_root="$HOME/work/herdr-inbox/jobs"
      ;;
    configured)
      export ARBITER_INBOX_ROOT="$TMP/configured-jobs"
      jobs_root="$ARBITER_INBOX_ROOT"
      ;;
    *) return 2 ;;
  esac
  "$ARBITER" claim --job "$job" --lane test-lane --agent-label test-label --t T1 >/dev/null
  "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json '{"owner_lane":"test-lane","label":"test-label","pane_id":"test:pane"}' >/dev/null
  report="$TMP/$job-report.md"
  printf 'completion report\n' >"$report"
  "$WRK" 'done' "$job" --report "$report" >/dev/null
  python3 - "$jobs_root/$job/events/00003-job.completed.json" "$job" <<'PY'
import json, sys
event = json.load(open(sys.argv[1]))
assert set(event) == {"kind", "job_id", "owner_lane", "label", "pane_id", "host", "report_path", "report_last_line", "epoch", "report_sha256"}, event
assert event["kind"] == "job.completed" and event["job_id"] == sys.argv[2], event
assert event["pane_id"] == "test:pane", (
    "pane_id is what panewire routes on; it must be the pane alone, not the rest of the metadata row: %r"
    % event["pane_id"])
assert event["epoch"] == 1, event
assert len(event["report_sha256"]) == 64, event
PY
)
real_done_case default
real_done_case configured
echo "PASS wrk-done-uses-arbiter-inbox-root-default-and-override"

# ── R20 T3: wrk notifies panewire once the record file has landed ────────────
# The event file stays the durable contract and the offline fallback; emit is
# only an extra notification that saves the node a directory rescan. It must
# never change wrk's stdout, its exit code, or how long wrk takes to return.
R20_HELPER="$TMP/r20_emit.py"
cat >"$R20_HELPER" <<'PY'
import json
import pathlib


def calls(log):
    """One list of argv elements per captured `panewire` invocation."""
    out, current = [], []
    for line in pathlib.Path(log).read_text(encoding="utf-8").split("\n")[:-1]:
        if line == "--":
            out.append(current)
            current = []
        else:
            current.append(line)
    assert not current, current
    return out


def flags(call):
    assert call[0] == "emit", call
    assert len(call) % 2 == 1, call
    return {call[i]: call[i + 1] for i in range(1, len(call), 2)}


def record(events, kind):
    for path in sorted(pathlib.Path(events).glob("*.json")):
        event = json.loads(path.read_text(encoding="utf-8"))
        if event.get("kind") == kind:
            return event
    raise AssertionError(f"no {kind} record under {events}")


def assert_matches_record(call, event):
    """Every field the two relay paths share must carry the record's value."""
    got = flags(call)
    assert got["--kind"] == event["kind"], (got, event)
    assert got["--job"] == event["job_id"], (got, event)
    assert got["--epoch"] == str(event["epoch"]) == "1", (got, event)
    assert got["--owner-lane"] == event["owner_lane"], (got, event)
    assert got["--label"] == event["label"], (got, event)
    assert got["--pane"] == event["pane_id"], (got, event)
    assert got["--host"] == event["host"], (got, event)
    assert got["--report"] == event["report_path"], (got, event)
    assert got["--report-last-line"] == event["report_last_line"], (got, event)
    for option, field in (
        ("--reason", "reason"), ("--question", "question"), ("--pr", "pr"), ("--head", "head")
    ):
        assert got.get(option, "") == event.get(field, ""), (option, got, event)
    return got
PY

R20_INBOX="$TMP/r20-inbox"
R20_REPORT="$TMP/r20-report.md"
printf 'R20 report terminal line\n' >"$R20_REPORT"
r20_arb() { env ARBITER_INBOX_ROOT="$R20_INBOX" XDG_DATA_HOME="$TMP/xdg-r20" "$ARBITER" "$@"; }
r20_claim() {  # a spawned worker job the completion commands can read back
  r20_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  r20_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}

# TW1 — the exact artifacts the production arbiter and wrk writers emit. The
# record files must stay byte-identical to the committed R19a fixture (no
# regression), and only then is the emit call examined.
R20_FIXTURE="$ROOT/tests/fixtures/panewire-r19a"
R20_FIXTURE_INBOX="$TMP/r20-fixture-inbox"
R20_FIXTURE_LOG="$TMP/r20-fixture-emit.log"
mkdir -p "$R20_FIXTURE_INBOX/captain-fixture/events"
cp "$R20_FIXTURE/00001-job.claim.json" "$R20_FIXTURE/00002-job.spawned.json" \
  "$R20_FIXTURE_INBOX/captain-fixture/events/"
(
  cd "$R20_FIXTURE"
  env ARBITER_INBOX_ROOT="$R20_FIXTURE_INBOX" HOSTNAME=fixture-host \
    WRK_PANEWIRE_LOG="$R20_FIXTURE_LOG" "$WRK" escalate captain-fixture \
    --question 'need parent decision' >/dev/null
  env ARBITER_INBOX_ROOT="$R20_FIXTURE_INBOX" HOSTNAME=fixture-host \
    WRK_PANEWIRE_LOG="$R20_FIXTURE_LOG" "$WRK" joined captain-fixture \
    --pr https://example.invalid/pr/1 --head deadbeef --report report.md >/dev/null
)
cmp "$R20_FIXTURE/00003-job.escalate.json" \
  "$R20_FIXTURE_INBOX/captain-fixture/events/00003-job.escalate.json"
cmp "$R20_FIXTURE/00004-job.joined.json" \
  "$R20_FIXTURE_INBOX/captain-fixture/events/00004-job.joined.json"
PYTHONPATH="$TMP" python3 - "$R20_FIXTURE_LOG" "$R20_FIXTURE_INBOX/captain-fixture/events" <<'PY'
import sys
import r20_emit as helper
log, events = sys.argv[1:]
captured = helper.calls(log)
assert len(captured) == 2, captured
for call, kind in zip(captured, ("job.escalate", "job.joined")):
    helper.assert_matches_record(call, helper.record(events, kind))
PY
echo "PASS r20-emit-on-real-arbiter-fixture-artifacts"

# TW2 — `wrk done` emits job.completed carrying the record's own values.
R20_DONE_LOG="$TMP/r20-done-emit.log"
r20_claim r20-done
r20_done_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_DONE_LOG" "$WRK" 'done' r20-done --report "$R20_REPORT")"
PYTHONPATH="$TMP" python3 - "$R20_DONE_LOG" "$R20_INBOX/r20-done/events" <<'PY'
import sys
import r20_emit as helper
log, events = sys.argv[1:]
captured = helper.calls(log)
assert len(captured) == 1, captured
got = helper.assert_matches_record(captured[0], helper.record(events, "job.completed"))
assert got["--kind"] == "job.completed" and got["--job"] == "r20-done", got
assert got["--report-last-line"] == "R20 report terminal line ", got
# `done` carries no reason/question/pr/head, so those options are left out
# entirely rather than passed as empty strings.
assert not {"--reason", "--question", "--pr", "--head"} & set(got), got
PY
grep -qxF "OK job=r20-done report=$R20_REPORT" <<<"$r20_done_out"
# A19 — a successful emit must leave zero trace in the failure marker.
[[ ! -e "$R20_INBOX/r20-done/emit-failures.log" ]]
echo "PASS r20-emit-argv-matches-done-record"

# TW3 — builder escalation carries --question, joined carries --pr/--head, and both carry
# the record's reason verbatim.
R20_BUILDER_LOG="$TMP/r20-builder-emit.log"
r20_claim r20-builder --role builder --parent-lane parent-a
r20_escalate_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_BUILDER_LOG" "$WRK" escalate r20-builder \
  --question 'need parent decision')"
r20_joined_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_LOG="$R20_BUILDER_LOG" "$WRK" joined r20-builder \
  --pr https://example.invalid/pr/1 --head deadbeef --report "$R20_REPORT")"
PYTHONPATH="$TMP" python3 - "$R20_BUILDER_LOG" "$R20_INBOX/r20-builder/events" <<'PY'
import sys
import r20_emit as helper
log, events = sys.argv[1:]
escalate_call, joined_call = helper.calls(log)
escalate = helper.assert_matches_record(escalate_call, helper.record(events, "job.escalate"))
joined = helper.assert_matches_record(joined_call, helper.record(events, "job.joined"))
assert escalate["--reason"] == "builder escalation", escalate
assert escalate["--question"] == "need parent decision", escalate
assert not {"--pr", "--head"} & set(escalate), escalate
assert joined["--reason"] == "builder joined PR", joined
assert joined["--pr"].endswith("/pr/1") and joined["--head"] == "deadbeef", joined
assert "--question" not in joined, joined
PY
echo "PASS r20-emit-argv-matches-builder-escalate-and-joined-records"

# TW4 — no panewire on the box: exit 0, the record is still written and both
# independently optional relays warn without changing stdout.
R20_ABSENT_ERR="$TMP/r20-absent.err"
r20_claim r20-absent
set +e
r20_absent_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" PANEWIRE_BIN="$TMP/absent-panewire" \
  HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' r20-absent --report "$R20_REPORT" 2>"$R20_ABSENT_ERR")"
r20_absent_rc=$?
set -e
[[ "$r20_absent_rc" -eq 0 ]]
[[ -f "$R20_INBOX/r20-absent/events/00003-job.completed.json" ]]
grep -qxF "OK job=r20-absent report=$R20_REPORT" <<<"$r20_absent_out"
grep -qxF 'wrk: warning: handoffkeep not found; report document not uploaded (job=r20-absent)' "$R20_ABSENT_ERR"
grep -qxF 'wrk: warning: panewire not found; relay event left as file only (job=r20-absent kind=job.completed)' "$R20_ABSENT_ERR"
[[ "$(wc -l <"$R20_ABSENT_ERR" | tr -d ' ')" -eq 2 ]]
# A19 — a warning on stderr is not durable; the failure to relay must be
# discoverable later from files alone, without re-reading logs.
[[ -f "$R20_INBOX/r20-absent/emit-failures.log" ]]
grep -q 'kind=job.completed rc=not_found' "$R20_INBOX/r20-absent/emit-failures.log"
echo "PASS r20-missing-panewire-warns-without-changing-exit-or-stdout"

# TW5 — emit fails: exit 0, the record is still written, the warning quotes rc.
R20_FAIL_ERR="$TMP/r20-fail.err"
r20_claim r20-fail
set +e
r20_fail_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" WRK_PANEWIRE_RC=3 \
  HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' r20-fail --report "$R20_REPORT" 2>"$R20_FAIL_ERR")"
r20_fail_rc=$?
set -e
[[ "$r20_fail_rc" -eq 0 ]]
[[ -f "$R20_INBOX/r20-fail/events/00003-job.completed.json" ]]
# #1014: a failed emit is loud twice — the report path in the warning and
# relay=file-only on the OK line.
grep -qxF "OK job=r20-fail report=$R20_REPORT relay=file-only" <<<"$r20_fail_out"
grep -qxF 'wrk: warning: handoffkeep not found; report document not uploaded (job=r20-fail)' "$R20_FAIL_ERR"
grep -qxF "wrk: warning: panewire emit failed (rc=3 job=r20-fail kind=job.completed report=$R20_REPORT); relay event left as file only" "$R20_FAIL_ERR"
[[ "$(wc -l <"$R20_FAIL_ERR" | tr -d ' ')" -eq 2 ]]
# A19 — same durable-failure trace as TW4, this time for a non-zero rc rather
# than a missing binary.
[[ -f "$R20_INBOX/r20-fail/emit-failures.log" ]]
grep -q 'kind=job.completed rc=3' "$R20_INBOX/r20-fail/emit-failures.log"
echo "PASS r20-failed-emit-warns-with-rc-without-changing-exit"

# TW6 — a wedged emit must not stall wrk: `wrk joined` runs inside the captain
# loop, so a hang there would stop the fleet. The 5s guard returns long before
# the fixture's 30s stall would.
R20_SLOW_ERR="$TMP/r20-slow.err"
r20_claim r20-slow
r20_slow_start_ns="$(python3 -c 'import time; print(time.time_ns())')"
set +e
r20_slow_out="$(env ARBITER_INBOX_ROOT="$R20_INBOX" WRK_PANEWIRE_SLEEP=30 \
  "$WRK" 'done' r20-slow --report "$R20_REPORT" 2>"$R20_SLOW_ERR")"
r20_slow_rc=$?
set -e
r20_slow_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - r20_slow_start_ns) / 1000000 ))"
echo "r20 wedged-emit: elapsed_ms=$r20_slow_ms rc=$r20_slow_rc"
[[ "$r20_slow_rc" -eq 0 ]]
[[ "$r20_slow_ms" -lt 10000 ]]
[[ -f "$R20_INBOX/r20-slow/events/00003-job.completed.json" ]]
# #1014: the emit timed out, so the OK line marks the relay file-only.
grep -qxF "OK job=r20-slow report=$R20_REPORT relay=file-only" <<<"$r20_slow_out"
grep -q 'panewire emit failed' "$R20_SLOW_ERR"
echo "PASS r20-wedged-emit-is-bounded-by-the-timeout-guard"

# TW7 — job.lost is not one of panewire's relay kinds, so the sentinel path
# must not emit at all; passing it would only pile up usage warnings.
R20_LOST_LOG="$TMP/r20-lost-emit.log"
R20_LOST_INBOX="$TMP/r20-lost-inbox"
set +e
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$R20_LOST_INBOX" WRK_PANEWIRE_LOG="$R20_LOST_LOG" \
  WRK_FIXTURE_SCENARIO=sentinel-working WRK_COMPLETION_TIMEOUT_S=1 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel r20-lost lane-a wrk-a w1:p1 "$R20_REPORT" >/dev/null 2>&1
r20_lost_rc=$?
set -e
[[ "$r20_lost_rc" -eq 0 ]]
find "$R20_LOST_INBOX/r20-lost/events" -name '*job.lost.json' | grep -q .
[[ ! -e "$R20_LOST_LOG" ]]
# A19 — emit_relay_event is never called for job.lost, so no failure marker
# either.
[[ ! -e "$R20_LOST_INBOX/r20-lost/emit-failures.log" ]]
echo "PASS r20-job-lost-is-never-emitted"

# TW8 — the stdout contract is exactly what it was before emit existed: one
# line, in the pre-R20 format, for each of the three commands.
[[ "$(wc -l <<<"$r20_done_out" | tr -d ' ')" -eq 1 ]]
[[ "$(wc -l <<<"$r20_escalate_out" | tr -d ' ')" -eq 1 ]]
[[ "$(wc -l <<<"$r20_joined_out" | tr -d ' ')" -eq 1 ]]
grep -qxF "OK job=r20-done report=$R20_REPORT" <<<"$r20_done_out"
grep -qxF 'OK job=r20-builder owner_lane=lane-a kind=job.escalate' <<<"$r20_escalate_out"
grep -qxF "OK job=r20-builder owner_lane=lane-a kind=job.joined pr=https://example.invalid/pr/1 head=deadbeef report=$R20_REPORT" <<<"$r20_joined_out"
echo "PASS r20-stdout-contract-unchanged"

# TW9 — emit must always name --inbox-root: panewire wants the root containing
# jobs/<job>/events, which is the parent of wrk_jobs_root() (ARBITER_INBOX_ROOT
# is the jobs directory itself). Without the flag the emit lands on the
# daemon's default root and the relay is lost; the fixture's opt-in
# WRK_PANEWIRE_REQUIRE_INBOX_ROOT turns that into the observed rc=2, which must
# therefore never reach the warning path for any of the three kinds.
R20_ROOT_LOG="$TMP/r20-inbox-root-emit.log"
R20_ROOT_ERR="$TMP/r20-inbox-root.err"
r20_claim r20-root-done
r20_claim r20-root-builder --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" 'done' r20-root-done --report "$R20_REPORT" 2>"$R20_ROOT_ERR" >/dev/null
env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" escalate r20-root-builder --question 'need parent decision' \
  2>>"$R20_ROOT_ERR" >/dev/null
env ARBITER_INBOX_ROOT="$R20_INBOX" HOSTNAME=fixture-host \
  WRK_PANEWIRE_REQUIRE_INBOX_ROOT=1 WRK_PANEWIRE_LOG="$R20_ROOT_LOG" \
  "$WRK" joined r20-root-builder --pr https://example.invalid/pr/1 \
  --head deadbeef --report "$R20_REPORT" 2>>"$R20_ROOT_ERR" >/dev/null
if grep -q 'panewire' "$R20_ROOT_ERR"; then
  fail "emit without --inbox-root is rc=2; the warning proves it was not passed: $(cat "$R20_ROOT_ERR")"
fi
PYTHONPATH="$TMP" python3 - "$R20_ROOT_LOG" "$(dirname "$R20_INBOX")" <<'PY'
import sys
import r20_emit as helper

log, inbox_root = sys.argv[1:]
captured = helper.calls(log)
assert len(captured) == 3, captured
kinds = []
for call in captured:
    got = helper.flags(call)
    assert got.get("--inbox-root") == inbox_root, got
    kinds.append(got["--kind"])
assert kinds == ["job.completed", "job.escalate", "job.joined"], kinds
PY
echo "PASS r20-emit-passes-inbox-root-parent-of-jobs-dir"

# ── R21: report documents are optional handoffkeep uploads ──────────────────
# Keep the capture shape identical to R20: a fixture collects every argv
# element, and real arbiter claim/spawned envelopes provide the command input.
R21_HANDOFFKEEP="$TMP/handoffkeep"
cat >"$R21_HANDOFFKEEP" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${WRK_HANDOFFKEEP_LOG:-}" ]]; then
  {
    for argument in "$@"; do printf '%s\n' "$argument"; done
    printf -- '--\n'
  } >>"$WRK_HANDOFFKEEP_LOG"
fi

[[ -z "${WRK_HANDOFFKEEP_SLEEP:-}" ]] || sleep "$WRK_HANDOFFKEEP_SLEEP"
exit "${WRK_HANDOFFKEEP_RC:-0}"
SH
chmod +x "$R21_HANDOFFKEEP"

R21_INBOX="$TMP/r21-inbox"
r21_arb() { env ARBITER_INBOX_ROOT="$R21_INBOX" XDG_DATA_HOME="$TMP/xdg-r21" "$ARBITER" "$@"; }
r21_claim() {
  r21_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  r21_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
r21_report() {
  local job="$1" name="$2" line="$3"
  local path="$R21_INBOX/$job/$name"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$line" >"$path"
  printf '%s\n' "$path"
}

# T1/T2/T9 — exact document argv, one call, and the same doc-suffixed last
# line in both the durable record and captured panewire argv. The fixture token
# proves that wrk neither reads nor prints the credential passed to the CLI.
R21_DONE_JOB="r21-done"
R21_DONE_REPORT="$(r21_report "$R21_DONE_JOB" report.md 'document terminal line')"
R21_DONE_HK_LOG="$TMP/r21-done-handoffkeep.log"
R21_DONE_PW_LOG="$TMP/r21-done-panewire.log"
R21_DONE_ERR="$TMP/r21-done.err"
r21_claim "$R21_DONE_JOB"
r21_done_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" HANDOFFKEEP_TOKEN=fixture-token \
  WRK_HANDOFFKEEP_LOG="$R21_DONE_HK_LOG" WRK_PANEWIRE_LOG="$R21_DONE_PW_LOG" \
  "$WRK" 'done' "$R21_DONE_JOB" --report "$R21_DONE_REPORT" 2>"$R21_DONE_ERR")"
PYTHONPATH="$TMP" python3 - "$R21_DONE_HK_LOG" "$R21_DONE_PW_LOG" "$R21_INBOX/$R21_DONE_JOB/events" "$R21_DONE_REPORT" <<'PY'
import sys
import r20_emit as helper

handoff, panewire, events, report = sys.argv[1:]
expected = ["doc", "put", "--key", "reports/r21-done/report.md", "--kind", "report",
            "--job", "r21-done", "--file", report]
assert helper.calls(handoff) == [expected], helper.calls(handoff)
event = helper.record(events, "job.completed")
call = helper.calls(panewire)
assert len(call) == 1, call
got = helper.assert_matches_record(call[0], event)
assert event["report_last_line"] == got["--report-last-line"], (event, got)
assert event["report_last_line"].endswith(" doc:reports/r21-done/report.md"), event
PY
grep -qxF "OK job=$R21_DONE_JOB report=$R21_DONE_REPORT" <<<"$r21_done_out"
[[ ! -s "$R21_DONE_ERR" ]]
if grep -qF 'fixture-token' "$R21_DONE_HK_LOG" || grep -qF 'fixture-token' <<<"$r21_done_out" \
  || grep -qF 'fixture-token' "$R21_DONE_ERR"; then
  fail "handoffkeep token leaked to an argv capture or wrk output"
fi
echo "PASS r21-done-document-argv-record-wire-and-token-hygiene"

# T3 — reserve space for the complete document suffix before truncating the
# original terminal line; a broken link is worse than a shortened summary.
R21_LONG_JOB="r21-long"
R21_LONG_REPORT="$R21_INBOX/$R21_LONG_JOB/report-long.md"
mkdir -p "$(dirname "$R21_LONG_REPORT")"
python3 -c 'print("x" * 300)' >"$R21_LONG_REPORT"
r21_claim "$R21_LONG_JOB"
env ARBITER_INBOX_ROOT="$R21_INBOX" HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  "$WRK" 'done' "$R21_LONG_JOB" --report "$R21_LONG_REPORT" >/dev/null
PYTHONPATH="$TMP" python3 - "$R21_INBOX/$R21_LONG_JOB/events" <<'PY'
import sys
import r20_emit as helper

last = helper.record(sys.argv[1], "job.completed")["report_last_line"]
suffix = " doc:reports/r21-long/report-long.md"
assert len(last) <= 240, len(last)
assert last.endswith(suffix), last
assert len(last) == 240, len(last)
PY
echo "PASS r21-document-suffix-survives-240-character-cap"

# T4 — a failed upload is one warning only; it must not alter the OK line,
# prevent the durable record/emit, or attach a document suffix.
R21_FAIL_JOB="r21-upload-fail"
R21_FAIL_REPORT="$(r21_report "$R21_FAIL_JOB" report.md 'upload failure terminal line')"
R21_FAIL_PW_LOG="$TMP/r21-fail-panewire.log"
R21_FAIL_ERR="$TMP/r21-fail.err"
r21_claim "$R21_FAIL_JOB"
set +e
r21_fail_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_RC=1 \
  WRK_PANEWIRE_LOG="$R21_FAIL_PW_LOG" "$WRK" 'done' "$R21_FAIL_JOB" \
  --report "$R21_FAIL_REPORT" 2>"$R21_FAIL_ERR")"
r21_fail_rc=$?
set -e
[[ "$r21_fail_rc" -eq 0 ]]
grep -qxF "OK job=$R21_FAIL_JOB report=$R21_FAIL_REPORT" <<<"$r21_fail_out"
grep -qxF 'wrk: warning: handoffkeep document upload failed (rc=1 job=r21-upload-fail); continuing without document link' "$R21_FAIL_ERR"
[[ "$(wc -l <"$R21_FAIL_ERR" | tr -d ' ')" -eq 1 ]]
PYTHONPATH="$TMP" python3 - "$R21_FAIL_PW_LOG" "$R21_INBOX/$R21_FAIL_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.completed")
call = helper.calls(sys.argv[1])
assert len(call) == 1, call
helper.assert_matches_record(call[0], event)
assert " doc:" not in event["report_last_line"], event
PY
echo "PASS r21-failed-document-upload-warns-and-continues"

# T5 — resolving no CLI at all has the same non-fatal, no-document result.
R21_ABSENT_JOB="r21-handoffkeep-absent"
R21_ABSENT_REPORT="$(r21_report "$R21_ABSENT_JOB" report.md 'absent terminal line')"
R21_ABSENT_PW_LOG="$TMP/r21-absent-panewire.log"
R21_ABSENT_ERR="$TMP/r21-absent.err"
r21_claim "$R21_ABSENT_JOB"
set +e
r21_absent_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$TMP/no-handoffkeep" WRK_PANEWIRE_LOG="$R21_ABSENT_PW_LOG" \
  "$WRK" 'done' "$R21_ABSENT_JOB" --report "$R21_ABSENT_REPORT" 2>"$R21_ABSENT_ERR")"
r21_absent_rc=$?
set -e
[[ "$r21_absent_rc" -eq 0 ]]
grep -qxF "OK job=$R21_ABSENT_JOB report=$R21_ABSENT_REPORT" <<<"$r21_absent_out"
grep -qxF 'wrk: warning: handoffkeep not found; report document not uploaded (job=r21-handoffkeep-absent)' "$R21_ABSENT_ERR"
[[ "$(wc -l <"$R21_ABSENT_ERR" | tr -d ' ')" -eq 1 ]]
PYTHONPATH="$TMP" python3 - "$R21_ABSENT_PW_LOG" "$R21_INBOX/$R21_ABSENT_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.completed")
call = helper.calls(sys.argv[1])
assert len(call) == 1, call
helper.assert_matches_record(call[0], event)
assert " doc:" not in event["report_last_line"], event
PY
echo "PASS r21-missing-handoffkeep-warns-and-continues"

# T6 — a stalled CLI is bounded by the three-second guard and otherwise has
# the T4 behavior. Its 30-second fixture delay must never escape the guard.
R21_SLOW_JOB="r21-handoffkeep-slow"
R21_SLOW_REPORT="$(r21_report "$R21_SLOW_JOB" report.md 'slow terminal line')"
R21_SLOW_PW_LOG="$TMP/r21-slow-panewire.log"
R21_SLOW_ERR="$TMP/r21-slow.err"
r21_claim "$R21_SLOW_JOB"
r21_slow_start_ns="$(python3 -c 'import time; print(time.time_ns())')"
set +e
r21_slow_out="$(env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_SLEEP=30 \
  WRK_PANEWIRE_LOG="$R21_SLOW_PW_LOG" "$WRK" 'done' "$R21_SLOW_JOB" \
  --report "$R21_SLOW_REPORT" 2>"$R21_SLOW_ERR")"
r21_slow_rc=$?
set -e
r21_slow_ms="$(( ($(python3 -c 'import time; print(time.time_ns())') - r21_slow_start_ns) / 1000000 ))"
[[ "$r21_slow_rc" -eq 0 ]]
[[ "$r21_slow_ms" -lt 10000 ]]
grep -qxF "OK job=$R21_SLOW_JOB report=$R21_SLOW_REPORT" <<<"$r21_slow_out"
grep -q 'handoffkeep document upload failed' "$R21_SLOW_ERR"
[[ "$(wc -l <"$R21_SLOW_ERR" | tr -d ' ')" -eq 1 ]]
PYTHONPATH="$TMP" python3 - "$R21_SLOW_PW_LOG" "$R21_INBOX/$R21_SLOW_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.completed")
call = helper.calls(sys.argv[1])
assert len(call) == 1, call
helper.assert_matches_record(call[0], event)
assert " doc:" not in event["report_last_line"], event
PY
echo "PASS r21-stalled-handoffkeep-is-bounded-by-three-second-guard elapsed_ms=$r21_slow_ms"

# T7 — joined follows the same upload and suffix rules, using the builder's
# own job id in the document command.
R21_JOINED_JOB="r21-joined"
R21_JOINED_REPORT="$(r21_report "$R21_JOINED_JOB" joined-report.md 'joined terminal line')"
R21_JOINED_HK_LOG="$TMP/r21-joined-handoffkeep.log"
R21_JOINED_PW_LOG="$TMP/r21-joined-panewire.log"
r21_claim "$R21_JOINED_JOB" --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_JOINED_HK_LOG" WRK_PANEWIRE_LOG="$R21_JOINED_PW_LOG" \
  "$WRK" joined "$R21_JOINED_JOB" --pr https://example.invalid/pr/21 --head deadbeef \
  --report "$R21_JOINED_REPORT" >/dev/null
PYTHONPATH="$TMP" python3 - "$R21_JOINED_HK_LOG" "$R21_JOINED_PW_LOG" "$R21_INBOX/$R21_JOINED_JOB/events" "$R21_JOINED_REPORT" <<'PY'
import sys
import r20_emit as helper

handoff, panewire, events, report = sys.argv[1:]
call = helper.calls(handoff)
assert len(call) == 1 and call[0][7] == "r21-joined", call
event = helper.record(events, "job.joined")
relay = helper.calls(panewire)
assert len(relay) == 1, relay
helper.assert_matches_record(relay[0], event)
assert event["report_last_line"].endswith(" doc:reports/r21-joined/joined-report.md"), event
PY
echo "PASS r21-joined-uploads-and-relays-document-link"

# T8 — escalation accepts an optional report; without it it retains the old
# empty report fields and makes no handoffkeep call. A missing report is fatal.
R21_ESC_JOB="r21-escalate-report"
R21_ESC_REPORT="$(r21_report "$R21_ESC_JOB" escalation.md 'escalation terminal line')"
R21_ESC_HK_LOG="$TMP/r21-escalate-handoffkeep.log"
R21_ESC_PW_LOG="$TMP/r21-escalate-panewire.log"
r21_claim "$R21_ESC_JOB" --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_ESC_HK_LOG" WRK_PANEWIRE_LOG="$R21_ESC_PW_LOG" \
  "$WRK" escalate "$R21_ESC_JOB" --question 'need a decision' --report "$R21_ESC_REPORT" >/dev/null
PYTHONPATH="$TMP" python3 - "$R21_ESC_HK_LOG" "$R21_ESC_PW_LOG" "$R21_INBOX/$R21_ESC_JOB/events" <<'PY'
import sys
import r20_emit as helper

handoff, panewire, events = sys.argv[1:]
assert len(helper.calls(handoff)) == 1, helper.calls(handoff)
event = helper.record(events, "job.escalate")
relay = helper.calls(panewire)
assert len(relay) == 1, relay
helper.assert_matches_record(relay[0], event)
assert event["report_path"].endswith("/escalation.md"), event
assert event["report_last_line"].endswith(" doc:reports/r21-escalate-report/escalation.md"), event
PY
R21_ESC_EMPTY_JOB="r21-escalate-empty"
R21_ESC_EMPTY_HK_LOG="$TMP/r21-escalate-empty-handoffkeep.log"
R21_ESC_EMPTY_PW_LOG="$TMP/r21-escalate-empty-panewire.log"
r21_claim "$R21_ESC_EMPTY_JOB" --role builder --parent-lane parent-a
env ARBITER_INBOX_ROOT="$R21_INBOX" HOSTNAME=fixture-host HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_ESC_EMPTY_HK_LOG" WRK_PANEWIRE_LOG="$R21_ESC_EMPTY_PW_LOG" \
  "$WRK" escalate "$R21_ESC_EMPTY_JOB" --question 'need a decision' >/dev/null
[[ ! -s "$R21_ESC_EMPTY_HK_LOG" ]]
PYTHONPATH="$TMP" python3 - "$R21_ESC_EMPTY_PW_LOG" "$R21_INBOX/$R21_ESC_EMPTY_JOB/events" <<'PY'
import sys
import r20_emit as helper

event = helper.record(sys.argv[2], "job.escalate")
relay = helper.calls(sys.argv[1])
assert len(relay) == 1, relay
helper.assert_matches_record(relay[0], event)
assert event["report_path"] == event["report_last_line"] == "", event
PY
R21_ESC_MISSING_JOB="r21-escalate-missing"
R21_ESC_MISSING_HK_LOG="$TMP/r21-escalate-missing-handoffkeep.log"
r21_claim "$R21_ESC_MISSING_JOB" --role builder --parent-lane parent-a
: >"$R21_ESC_MISSING_HK_LOG"
set +e
env ARBITER_INBOX_ROOT="$R21_INBOX" HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" \
  WRK_HANDOFFKEEP_LOG="$R21_ESC_MISSING_HK_LOG" "$WRK" escalate "$R21_ESC_MISSING_JOB" \
  --question 'need a decision' --report "$TMP/no-such-report.md" >/dev/null 2>&1
r21_esc_missing_rc=$?
set -e
[[ "$r21_esc_missing_rc" -ne 0 ]]
[[ ! -s "$R21_ESC_MISSING_HK_LOG" ]]
echo "PASS r21-escalate-report-optional-and-missing-path-is-fatal"

# ── #1014: a later-round `wrk done` must relay, not collide ─────────────────
# panewire's emit outbox key is (kind, job, epoch, report_path, reason), and
# the fixture now refuses a same-key emit for a different record with rc 6
# exactly like writeEmitRecord. A fix round that updates report.md in place
# must therefore be relayed under a fresh artifact path: the durable record,
# the handoffkeep document upload, the emit argv and the OK line all name it.
# ARBITER_INBOX_ROOT ends in /jobs here so the emit --inbox-root (the parent
# directory) resolves <root>/jobs/<job>/events to this very events dir — the
# fixture's duplicate-key scan is then exercised rather than vacuous.
RND_INBOX="$TMP/rnd-inbox"
RND_JOBS="$RND_INBOX/jobs"
mkdir -p "$RND_JOBS"
rnd_arb() { env ARBITER_INBOX_ROOT="$RND_JOBS" XDG_DATA_HOME="$TMP/xdg-rnd" "$ARBITER" "$@"; }
rnd_claim() {
  rnd_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  rnd_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
rnd_report() {
  local path="$RND_JOBS/$1/$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$3" >"$path"
  printf '%s\n' "$path"
}

# AC1 — round 2 on the same path: snapshot to report-r2.md and relay under it.
RND1_JOB="rnd-same-path"
RND1_HK_LOG="$TMP/rnd1-handoffkeep.log"
RND1_PW_LOG="$TMP/rnd1-panewire.log"
rnd_claim "$RND1_JOB"
rnd1_report="$(rnd_report "$RND1_JOB" report.md 'round one terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND1_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND1_PW_LOG" "$WRK" 'done' "$RND1_JOB" --report "$rnd1_report" >/dev/null
printf 'round two terminal line\n' >"$rnd1_report"
rnd1_second="$(env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND1_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND1_PW_LOG" "$WRK" 'done' "$RND1_JOB" --report "$rnd1_report")"
rnd1_snapshot="$RND_JOBS/$RND1_JOB/report-r2.md"
[[ -f "$rnd1_snapshot" ]] ||
  fail "a changed report.md on an already-completed path must be snapshot to report-r2.md"
grep -qxF "OK job=$RND1_JOB report=$rnd1_snapshot" <<<"$rnd1_second" ||
  fail "the OK line must name the snapshot path: $rnd1_second"
grep -qxF 'round two terminal line' "$rnd1_report" ||
  fail "the original report.md must stay untouched"
grep -qxF 'round two terminal line' "$rnd1_snapshot" ||
  fail "the snapshot must carry the new report content"
PYTHONPATH="$TMP" python3 - "$RND1_HK_LOG" "$RND1_PW_LOG" \
  "$RND_JOBS/$RND1_JOB/events" "$rnd1_report" "$rnd1_snapshot" <<'PY'
import glob, hashlib, json, pathlib, sys
import r20_emit as helper

handoff_log, panewire_log, events, report, snapshot = sys.argv[1:]
uploads = helper.calls(handoff_log)
assert len(uploads) == 2, uploads
assert uploads[0][3] == "reports/rnd-same-path/report.md" and uploads[0][-1] == report, uploads[0]
assert uploads[1][3] == "reports/rnd-same-path/report-r2.md" and uploads[1][-1] == snapshot, uploads[1]
emits = helper.calls(panewire_log)
assert len(emits) == 2, emits
assert helper.flags(emits[0])["--report"] == report, emits[0]
assert helper.flags(emits[1])["--report"] == snapshot, emits[1]
records = [json.loads(p.read_text()) for p in sorted(pathlib.Path(events).glob("*job.completed.json"))]
assert [r["report_path"] for r in records] == [report, snapshot], records
assert records[1]["report_sha256"] == hashlib.sha256(pathlib.Path(snapshot).read_bytes()).hexdigest()
assert records[0]["report_sha256"] != records[1]["report_sha256"], records
helper.assert_matches_record(emits[1], records[1])
assert records[1]["report_last_line"].endswith(" doc:reports/rnd-same-path/report-r2.md"), records[1]
PY
echo "PASS 1014-ac1-later-round-done-relays-under-snapshot-path"

# AC2 — unchanged content on the same path stays a suppressed duplicate: no
# second record, no second emit, no snapshot file.
RND2_JOB="rnd-identical"
RND2_HK_LOG="$TMP/rnd2-handoffkeep.log"
RND2_PW_LOG="$TMP/rnd2-panewire.log"
RND2_ERR="$TMP/rnd2.err"
rnd_claim "$RND2_JOB"
rnd2_report="$(rnd_report "$RND2_JOB" report.md 'same terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND2_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND2_PW_LOG" "$WRK" 'done' "$RND2_JOB" --report "$rnd2_report" >/dev/null
rnd2_second="$(env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND2_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND2_PW_LOG" "$WRK" 'done' "$RND2_JOB" --report "$rnd2_report" 2>"$RND2_ERR")"
grep -qxF "OK job=$RND2_JOB report=$rnd2_report" <<<"$rnd2_second" ||
  fail "a suppressed duplicate still prints the caller's report path: $rnd2_second"
grep -q 'job.completed already recorded for this report; suppressed duplicate' "$RND2_ERR" ||
  fail "the duplicate suppression must stay a warning, got: $(cat "$RND2_ERR")"
grep -q "suppressed-duplicate report=$rnd2_report" "$RND_JOBS/$RND2_JOB/completion-suppressed.log" ||
  fail "the suppressed duplicate must leave its durable note"
[[ "$(find "$RND_JOBS/$RND2_JOB/events" -name '*job.completed.json' | wc -l | tr -d ' ')" == 1 ]] ||
  fail "a suppressed duplicate writes no second job.completed record"
[[ ! -e "$RND_JOBS/$RND2_JOB/report-r2.md" ]] ||
  fail "an identical report must not be snapshot"
PYTHONPATH="$TMP" python3 - "$RND2_HK_LOG" "$RND2_PW_LOG" <<'PY'
import sys
import r20_emit as helper

assert len(helper.calls(sys.argv[1])) == 1, helper.calls(sys.argv[1])
assert len(helper.calls(sys.argv[2])) == 1, helper.calls(sys.argv[2])
PY
echo "PASS 1014-ac2-identical-report-still-suppressed"

# AC3 — a caller that already names a fresh path gets no second snapshot: the
# record, upload and emit use report-r2.md verbatim.
RND3_JOB="rnd-new-path"
RND3_HK_LOG="$TMP/rnd3-handoffkeep.log"
RND3_PW_LOG="$TMP/rnd3-panewire.log"
rnd_claim "$RND3_JOB"
rnd3_first="$(rnd_report "$RND3_JOB" report.md 'round one terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND3_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND3_PW_LOG" "$WRK" 'done' "$RND3_JOB" --report "$rnd3_first" >/dev/null
rnd3_report="$(rnd_report "$RND3_JOB" report-r2.md 'explicit round two path')"
rnd3_out="$(env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
  HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" WRK_HANDOFFKEEP_LOG="$RND3_HK_LOG" \
  WRK_PANEWIRE_LOG="$RND3_PW_LOG" "$WRK" 'done' "$RND3_JOB" --report "$rnd3_report")"
grep -qxF "OK job=$RND3_JOB report=$rnd3_report" <<<"$rnd3_out" ||
  fail "an explicit fresh path must be used verbatim: $rnd3_out"
[[ ! -e "$RND_JOBS/$RND3_JOB/report-r3.md" ]] ||
  fail "an explicit new path must not be snapshot again"
PYTHONPATH="$TMP" python3 - "$RND3_HK_LOG" "$RND3_PW_LOG" \
  "$RND_JOBS/$RND3_JOB/events" "$rnd3_report" <<'PY'
import json, pathlib, sys
import r20_emit as helper

handoff_log, panewire_log, events, report = sys.argv[1:]
uploads = helper.calls(handoff_log)
assert len(uploads) == 2, uploads
assert uploads[1][3] == "reports/rnd-new-path/report-r2.md" and uploads[1][-1] == report, uploads[1]
emits = helper.calls(panewire_log)
assert len(emits) == 2, emits
assert helper.flags(emits[1])["--report"] == report, emits[1]
records = [json.loads(p.read_text()) for p in sorted(pathlib.Path(events).glob("*job.completed.json"))]
assert records[-1]["report_path"] == report, records
helper.assert_matches_record(emits[1], records[-1])
PY
echo "PASS 1014-ac3-explicit-new-path-needs-no-snapshot"

# AC4 — the completion sentinel and `wrk done` racing on the same changed
# report land exactly one record for the round and exactly one snapshot file:
# the events lock serializes the resolve-and-write decision.
RND4_JOB="rnd-sentinel-race"
RND4_PW_LOG="$TMP/rnd4-panewire.log"
rnd_claim "$RND4_JOB"
rnd4_report="$(rnd_report "$RND4_JOB" report.md 'round one terminal line')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  WRK_PANEWIRE_LOG="$RND4_PW_LOG" "$WRK" 'done' "$RND4_JOB" --report "$rnd4_report" >/dev/null
# A fix round revives the job — a spawned record newer than the round-1
# terminal keeps the sentinel watching instead of watch-exiting.
rnd_arb event --job "$RND4_JOB" --kind job.spawned \
  --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
printf 'round two terminal line\n' >"$rnd4_report"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$RND_JOBS" \
  WRK_FIXTURE_SCENARIO=sentinel-done WRK_COMPLETION_TIMEOUT_S=30 \
  WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel "$RND4_JOB" lane-a wrk-a w1:p1 "$rnd4_report" >/dev/null 2>&1 &
rnd4_sentinel=$!
# done lands inside the sentinel's settle window, so both processes reach
# completion_event on the same changed report.
sleep 2
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  WRK_PANEWIRE_LOG="$RND4_PW_LOG" "$WRK" 'done' "$RND4_JOB" --report "$rnd4_report" >/dev/null 2>&1
rnd4_done_rc=$?
# Whichever side won, both left: done returned above, and the sentinel exits
# on its own completed write or on the watch-exit check that follows it.
wait_until 20 bash -c "! kill -0 $rnd4_sentinel 2>/dev/null" ||
  fail "the sentinel must exit once the raced round completed"
wait "$rnd4_sentinel" 2>/dev/null || true
[[ "$rnd4_done_rc" -eq 0 ]] || fail "wrk done during a sentinel race must still exit 0"
[[ -f "$RND_JOBS/$RND4_JOB/report-r2.md" ]] ||
  fail "the raced round must have produced exactly the report-r2.md snapshot"
[[ ! -e "$RND_JOBS/$RND4_JOB/report-r3.md" ]] ||
  fail "the events lock must prevent a second snapshot of the same round"
PYTHONPATH="$TMP" python3 - "$RND4_PW_LOG" "$RND_JOBS/$RND4_JOB/events" \
  "$rnd4_report" "$RND_JOBS/$RND4_JOB/report-r2.md" <<'PY'
import hashlib, json, pathlib, sys
import r20_emit as helper

panewire_log, events, report, snapshot = sys.argv[1:]
records = [json.loads(p.read_text()) for p in sorted(pathlib.Path(events).glob("*job.completed.json"))]
paths = [r["report_path"] for r in records]
assert paths == [report, snapshot], paths
assert records[1]["report_sha256"] == hashlib.sha256(pathlib.Path(snapshot).read_bytes()).hexdigest()
round_two_emits = [c for c in helper.calls(panewire_log)
                   if helper.flags(c)["--report"] == snapshot]
assert len(round_two_emits) <= 1, round_two_emits
PY
echo "PASS 1014-ac4-sentinel-done-race-yields-one-record-one-snapshot"

# AC5 — a non-zero emit is loud: stderr names the job, report path and rc, and
# the OK line carries relay=file-only; the exit status stays what it was.
RND5_JOB="rnd-loud-failure"
RND5_ERR="$TMP/rnd5.err"
rnd_claim "$RND5_JOB"
rnd5_report="$(rnd_report "$RND5_JOB" report.md 'loud failure line')"
set +e
rnd5_out="$(env ARBITER_INBOX_ROOT="$RND_JOBS" WRK_PANEWIRE_RC=6 \
  HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' "$RND5_JOB" --report "$rnd5_report" 2>"$RND5_ERR")"
rnd5_rc=$?
set -e
[[ "$rnd5_rc" -eq 0 ]] ||
  fail "a failed emit must not change the done exit status, got $rnd5_rc"
grep -qxF "OK job=$RND5_JOB report=$rnd5_report relay=file-only" <<<"$rnd5_out" ||
  fail "a failed emit must mark the OK line relay=file-only: $rnd5_out"
grep -qxF "wrk: warning: panewire emit failed (rc=6 job=$RND5_JOB kind=job.completed report=$rnd5_report); relay event left as file only" "$RND5_ERR" ||
  fail "a failed emit must name job, report path and rc on stderr: $(cat "$RND5_ERR")"
echo "PASS 1014-ac5-failed-emit-is-loud-and-exit-status-unchanged"

# S3 — the delegated path (WRK_PANEWIRE_JOB=present, probe → panewire-job/1)
# must carry the snapshot path too: `panewire job done` records and emits
# whatever --report it is handed, so resolve runs before delegate_job_cmd.
# The fixture's job-done writes the record itself and refuses a same
# outbox-key/different-content call with rc 6, so a leaked original path is
# observable as both a wrong argv and a failing delegated call.
RND6_JOB="rnd-delegated"
RND6_PW_JOB_LOG="$TMP/rnd6-pw-job.log"
RND6_ERR="$TMP/rnd6.err"
rnd_claim "$RND6_JOB"
rnd6_report="$(rnd_report "$RND6_JOB" report.md 'delegated round one')"
rnd6_snap2="$RND_JOBS/$RND6_JOB/report-r2.md"
rnd6_snap3="$RND_JOBS/$RND6_JOB/report-r3.md"
rnd6_done() {
  env ARBITER_INBOX_ROOT="$RND_JOBS" HOSTNAME=fixture-host \
    HANDOFFKEEP_BIN="$R21_HANDOFFKEEP" PANEWIRE_BIN="$PANEWIRE" \
    WRK_PANEWIRE_JOB=present WRK_PANEWIRE_JOB_LOG="$RND6_PW_JOB_LOG" \
    "$WRK" 'done' "$RND6_JOB" --report "$rnd6_report"
}
rnd6_first="$(rnd6_done)"
[[ "$rnd6_first" == "fixture job done $RND6_JOB --report $rnd6_report" ]] ||
  fail "rnd-delegated r1: delegated stdout must pass through: $rnd6_first"
grep -qxF "HOSTNAME=fixture-host [done] [$RND6_JOB] [--report] [$rnd6_report]" "$RND6_PW_JOB_LOG" ||
  fail "rnd-delegated r1: delegated argv must name report.md: $(cat "$RND6_PW_JOB_LOG")"

printf 'delegated round two\n' >"$rnd6_report"
rnd6_second="$(rnd6_done 2>"$RND6_ERR")"
[[ "$rnd6_second" == "fixture job done $RND6_JOB --report $rnd6_snap2" ]] ||
  fail "rnd-delegated r2: delegated argv must name the snapshot: $rnd6_second"
grep -qxF "HOSTNAME=fixture-host [done] [$RND6_JOB] [--report] [$rnd6_snap2]" "$RND6_PW_JOB_LOG" ||
  fail "rnd-delegated r2: panewire must be handed report-r2.md: $(cat "$RND6_PW_JOB_LOG")"
! grep -q 'delegation failed' "$RND6_ERR" ||
  fail "rnd-delegated r2: the delegated call must not hit the duplicate-key rc 6: $(cat "$RND6_ERR")"

printf 'delegated round three\n' >"$rnd6_report"
rnd6_third="$(rnd6_done 2>"$RND6_ERR")"
[[ "$rnd6_third" == "fixture job done $RND6_JOB --report $rnd6_snap3" ]] ||
  fail "rnd-delegated r3: delegated argv must name the snapshot: $rnd6_third"
grep -qxF "HOSTNAME=fixture-host [done] [$RND6_JOB] [--report] [$rnd6_snap3]" "$RND6_PW_JOB_LOG" ||
  fail "rnd-delegated r3: panewire must be handed report-r3.md: $(cat "$RND6_PW_JOB_LOG")"
! grep -q 'delegation failed' "$RND6_ERR" ||
  fail "rnd-delegated r3: the delegated call must not hit the duplicate-key rc 6: $(cat "$RND6_ERR")"

# Identical re-done: the delegated round-3 record carries report_sha256, so the
# wrk-side resolve suppresses it before delegation — the job log stays at 3.
rnd6_dup="$(rnd6_done 2>"$RND6_ERR")"
[[ "$rnd6_dup" == "OK job=$RND6_JOB report=$rnd6_report" ]] ||
  fail "rnd-delegated identical: suppression prints the caller's path: $rnd6_dup"
grep -q 'suppressed duplicate' "$RND6_ERR" ||
  fail "rnd-delegated identical: suppression must warn: $(cat "$RND6_ERR")"
[[ "$(wc -l <"$RND6_PW_JOB_LOG" | tr -d ' ')" == 3 ]] ||
  fail "rnd-delegated identical: a suppressed round must not delegate: $(cat "$RND6_PW_JOB_LOG")"
python3 - "$RND_JOBS/$RND6_JOB/events" "$rnd6_report" "$rnd6_snap2" "$rnd6_snap3" <<'PY'
import json, os, sys
events, p1, p2, p3 = sys.argv[1:]
paths = []
for name in sorted(os.listdir(events)):
    if "job.completed" in name and name.endswith(".json"):
        with open(os.path.join(events, name)) as f:
            paths.append(json.load(f).get("report_path"))
assert paths == [p1, p2, p3], f"delegated rounds must record {p1}, {p2}, {p3}; got {paths}"
PY
echo "PASS 1014-s3-delegated-later-rounds-name-snapshots"

# S1 (TOCTOU): completion_event must hash the bytes it snapshots, so the
# record's report_sha256 always equals the sha256 of the file it names even
# when report.md is rewritten while resolve waits on the events lock.
RND7_JOB="rnd-toctou"
RND7_ERR="$TMP/rnd7.err"
rnd_claim "$RND7_JOB"
rnd7_report="$(rnd_report "$RND7_JOB" report.md 'toctou round one')"
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' "$RND7_JOB" --report "$rnd7_report" >/dev/null
python3 - "$RND_JOBS/$RND7_JOB/.wrk-events.lock" "$TMP/rnd7-lock-held" <<'PY' &
import fcntl, sys, time
f = open(sys.argv[1], "w")
fcntl.flock(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").write("held")
time.sleep(5)
PY
rnd7_holder=$!
wait_until 10 test -f "$TMP/rnd7-lock-held" ||
  fail "rnd-toctou: the lock helper must take the events lock"
printf 'toctou round two\n' >"$rnd7_report"
env ARBITER_INBOX_ROOT="$RND_JOBS" HANDOFFKEEP_BIN="$TMP/absent-handoffkeep" \
  "$WRK" 'done' "$RND7_JOB" --report "$rnd7_report" >"$TMP/rnd7.out" 2>"$RND7_ERR" &
rnd7_done=$!
sleep 1
printf 'toctou round three\n' >"$rnd7_report"
wait "$rnd7_holder"
rnd7_rc=0
wait "$rnd7_done" || rnd7_rc=$?
[[ "$rnd7_rc" -eq 0 ]] || fail "rnd-toctou: done must exit 0, got $rnd7_rc: $(cat "$RND7_ERR")"
python3 - "$RND_JOBS/$RND7_JOB/events" <<'PY'
import hashlib, json, os, sys
events = sys.argv[1]
recs = []
for name in sorted(os.listdir(events)):
    if "job.completed" in name and name.endswith(".json"):
        with open(os.path.join(events, name)) as f:
            recs.append(json.load(f))
assert len(recs) == 2, f"expected 2 completion records, got {len(recs)}"
rec = recs[-1]
actual = hashlib.sha256(open(rec["report_path"], "rb").read()).hexdigest()
assert actual == rec["report_sha256"], \
    f"record names {rec['report_path']} whose sha256 {actual} != report_sha256 {rec['report_sha256']}"
PY
echo "PASS 1014-s1-snapshot-bytes-match-record-digest"

# R18 completion sentinel: a report alone is never completion evidence. A
# worker still working must time out/lost rather than emit job.completed.
SENTINEL_REPORT="$TMP/sentinel-report.md"
printf 'sentinel final line\n' >"$SENTINEL_REPORT"
SENTINEL_INBOX="$TMP/sentinel-inbox"
set +e
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-working WRK_COMPLETION_TIMEOUT_S=1 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel sentinel-working lane worker w:p1 "$SENTINEL_REPORT" >/dev/null 2>&1
sentinel_working_rc=$?
set -e
[[ "$sentinel_working_rc" -eq 0 ]]
if find "$SENTINEL_INBOX/sentinel-working/events" -name '*job.completed.json' | grep -q .; then
  echo "working agent incorrectly emitted job.completed" >&2
  exit 1
fi
find "$SENTINEL_INBOX/sentinel-working/events" -name '*job.lost.json' | grep -q .
python3 - "$SENTINEL_INBOX/sentinel-working/events" <<'PY'
import glob, json, sys
lost = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.lost.json"))]
assert lost and lost[0].get("reason") == "timeout", (
    "an expired watch window is job.lost with reason=timeout, got %r" % lost)
PY
echo "PASS r18-sentinel-requires-terminal-status"

# Automatic discovery must work on macOS too, and the observation key must be
# stable for an unchanged report but advance when that same report is updated.
SENTINEL_INBOX="$TMP/sentinel-dedupe-inbox"
env ARBITER_INBOX_ROOT="$SENTINEL_INBOX" "$ARBITER" claim \
  --job sentinel-idle --lane test-lane --agent-label test-label --t T1 >/dev/null
env ARBITER_INBOX_ROOT="$SENTINEL_INBOX" "$ARBITER" event --job sentinel-idle \
  --kind job.spawned --payload-json '{"owner_lane":"test-lane","label":"test-label","pane_id":"test:pane"}' >/dev/null
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=20 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel sentinel-idle lane worker w:p1 "" >/dev/null 2>&1 &
sentinel_idle_pid=$!
sleep 2
event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 0 ||
  fail "a job with no report is not complete, whatever the pane status says (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
cp "$SENTINEL_REPORT" "$SENTINEL_INBOX/sentinel-idle/report.md"
# the report must sit unchanged for one interval before it counts as final —
# the first sighting only logs action=pending.
wait_until 30 event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 1 ||
  fail "an idle pane plus a settled report is exactly one job.completed (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
# #770: the sentinel exits right after job.completed — a later report update
# can no longer mint a second completion, and the watcher must be gone.
wait_until 30 bash -c "! kill -0 $sentinel_idle_pid 2>/dev/null" ||
  fail "the completion sentinel must exit once job.completed lands"
printf 'updated report line\n' >>"$SENTINEL_INBOX/sentinel-idle/report.md"
sleep 2
event_count_is "$SENTINEL_INBOX/sentinel-idle/events" job.completed 1 ||
  fail "no sentinel remains after job.completed, so a report update writes no second record (got $(event_count "$SENTINEL_INBOX/sentinel-idle/events" job.completed))"
wait "$sentinel_idle_pid" 2>/dev/null || true
echo "PASS r18-sentinel-portable-discovery-and-dedupe"

# Both terminal statuses are accepted; `done` is tested separately so this is
# an explicit status-set contract rather than an idle-only implementation.
SENTINEL_INBOX="$TMP/sentinel-done-inbox"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$SENTINEL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-done WRK_COMPLETION_TIMEOUT_S=20 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel sentinel-done lane worker w:p1 "$SENTINEL_REPORT" >/dev/null 2>&1 &
sentinel_done_pid=$!
wait_until 30 event_count_is "$SENTINEL_INBOX/sentinel-done/events" job.completed 1 ||
  fail "a done pane plus a settled report is exactly one job.completed (got $(event_count "$SENTINEL_INBOX/sentinel-done/events" job.completed))"
kill "$sentinel_done_pid" 2>/dev/null || true
wait "$sentinel_done_pid" 2>/dev/null || true
echo "PASS r18-sentinel-accepts-done-status"

# ---------------------------------------------------------------------------
# 센티널 판정: 빈 값은 소멸의 증거가 아니다 (job.lost 오탐 수정)
# ---------------------------------------------------------------------------

# (a) 빈 출력·exit 1·JSON 파싱 실패·소켓 에러가 연속 임계 미만이면 소멸이 아니다.
# 그 뒤 정상 상태가 오면 판정은 completed 여야 하고 job.lost 는 하나도 없어야 한다.
TRANSIENT_INBOX="$TMP/sentinel-transient-inbox"
TRANSIENT_SEQ="$TMP/sentinel-transient.seq"
printf '%s\n' empty exit1 garbage socket working idle >"$TRANSIENT_SEQ"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$TRANSIENT_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$TRANSIENT_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=120 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=10 WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel sentinel-transient lane-a worker w1:p1 "$SENTINEL_REPORT" >/dev/null 2>&1 &
transient_pid=$!
TRANSIENT_EVENTS="$TRANSIENT_INBOX/sentinel-transient/events"
wait_until 30 event_count_is "$TRANSIENT_EVENTS" job.completed 1 ||
  fail "transient herdr failures below WRK_SENTINEL_TRANSIENT_MAX must still reach job.completed (got $(event_count "$TRANSIENT_EVENTS" job.completed))"
kill "$transient_pid" 2>/dev/null || true
wait "$transient_pid" 2>/dev/null || true
[[ "$(event_count "$TRANSIENT_EVENTS" job.lost)" -eq 0 ]] ||
  fail "empty/failed 'agent get' output is not pane loss: job.lost written with reason=$(sentinel_lost_reason "$TRANSIENT_EVENTS")"
transient_log="$TRANSIENT_INBOX/sentinel-transient/completion-sentinel.log"
[[ -s "$transient_log" ]] || fail "completion-sentinel.log must record one line per decision, but it is empty"
transient_seen="$(awk '{print $2, $3, $4}' "$transient_log" | head -7)"
transient_want='status=empty transient=1 action=none
status=err:exit1 transient=2 action=none
status=err:parse transient=3 action=none
status=err:transport_unavailable transient=4 action=none
status=working transient=0 action=none
status=idle transient=0 action=pending
status=idle transient=0 action=completed'
[[ "$transient_seen" == "$transient_want" ]] ||
  fail "sentinel decision log must classify each observation; want:
$transient_want
got:
$transient_seen"
echo "PASS sentinel-tolerates-transient-herdr-failures"

# (a') 연속 실패가 임계를 넘으면 herdr_unreachable 로 lost 하되, 유예 동안 계속
# 감시해 report + 종료 상태가 나타나면 completed 를 추가로 쓴다.
GRACE_INBOX="$TMP/sentinel-grace-inbox"
GRACE_SEQ="$TMP/sentinel-grace.seq"
printf '%s\n' empty empty empty empty idle >"$GRACE_SEQ"
GRACE_REPORT="$TMP/sentinel-grace-report.md"
rm -f "$GRACE_REPORT"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$GRACE_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$GRACE_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=3 WRK_SENTINEL_LOST_GRACE=120 \
  "$WRK" sentinel sentinel-grace lane-a worker w1:p1 "$GRACE_REPORT" >/dev/null 2>&1 &
grace_pid=$!
GRACE_EVENTS="$GRACE_INBOX/sentinel-grace/events"
wait_until 30 event_count_is "$GRACE_EVENTS" job.lost 1 ||
  fail "more than WRK_SENTINEL_TRANSIENT_MAX consecutive unreachable observations must end in job.lost"
[[ "$(sentinel_lost_reason "$GRACE_EVENTS")" == "herdr_unreachable" ]] ||
  fail "job.lost from consecutive observation failures must carry reason=herdr_unreachable, got '$(sentinel_lost_reason "$GRACE_EVENTS")'"
[[ "$(event_count "$GRACE_EVENTS" job.completed)" -eq 0 ]] ||
  fail "no report existed yet, so nothing may be completed at this point"
printf 'grace report line\n' >"$GRACE_REPORT"
wait_until 30 event_count_is "$GRACE_EVENTS" job.completed 1 ||
  fail "a report that appears within WRK_SENTINEL_LOST_GRACE must still produce job.completed after job.lost"
wait_until 15 bash -c "! kill -0 $grace_pid 2>/dev/null" ||
  fail "the sentinel must exit once it has completed a job it had already reported lost"
wait "$grace_pid" 2>/dev/null || true
grace_log="$GRACE_INBOX/sentinel-grace/completion-sentinel.log"
grace_lines="$(awk 'END{print NR}' "$grace_log")"
grace_calls="$(awk 'END{print NR}' "$GRACE_SEQ.calls")"
[[ "$grace_lines" -eq "$grace_calls" ]] ||
  fail "completion-sentinel.log must hold exactly one line per decision: $grace_lines lines for $grace_calls observations"
grep -q 'action=lost:herdr_unreachable' "$grace_log" ||
  fail "the decision log must name the lost reason it wrote (action=lost:herdr_unreachable)"
grep -q 'action=completed' "$grace_log" ||
  fail "the decision log must record the post-lost completion"
echo "PASS sentinel-lost-grace-still-completes"

# (b) 확정 소멸 코드는 즉시 lost 다 — 여기서만 재시도가 없다.
GONE_INBOX="$TMP/sentinel-gone-inbox"
GONE_SEQ="$TMP/sentinel-gone.seq"
printf '%s\n' not-found >"$GONE_SEQ"
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$GONE_INBOX" \
  WRK_FIXTURE_GET_SEQUENCE="$GONE_SEQ" \
  WRK_COMPLETION_TIMEOUT_S=300 WRK_COMPLETION_INTERVAL_S=1 \
  WRK_SENTINEL_TRANSIENT_MAX=10 WRK_SENTINEL_LOST_GRACE=0 \
  "$WRK" sentinel sentinel-gone lane-a worker w1:p1 "$SENTINEL_REPORT" >/dev/null 2>&1
GONE_EVENTS="$GONE_INBOX/sentinel-gone/events"
[[ "$(event_count "$GONE_EVENTS" job.lost)" -eq 1 ]] ||
  fail "an explicit agent_not_found is confirmed pane loss and must be reported at once"
[[ "$(sentinel_lost_reason "$GONE_EVENTS")" == "agent_not_found" ]] ||
  fail "job.lost must carry reason=agent_not_found, got '$(sentinel_lost_reason "$GONE_EVENTS")'"
gone_log="$GONE_INBOX/sentinel-gone/completion-sentinel.log"
[[ "$(awk 'END{print NR}' "$gone_log")" -eq 1 ]] ||
  fail "one observation is one decision is one log line"
grep -q 'status=err:agent_not_found transient=0 action=lost:agent_not_found' "$gone_log" ||
  fail "the decision log must show the error code that proved the loss"
echo "PASS sentinel-agent-not-found-is-immediate-loss"

# 분리된 센티널은 wrk 가 쓰던 herdr 세션을 명시적으로 물려받아야 한다. 상속에
# 기대면 비기본 세션 호스트에서 기본 소켓을 물어 영원히 빈 값을 본다.
ENV_INBOX="$TMP/sentinel-env-inbox"
ENV_LOG="$TMP/sentinel-env.log"
: >"$ENV_LOG"
env -u HERDR_SESSION -u HERDR_SOCKET_PATH \
  HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
  ARBITER_INBOX_ROOT="$ENV_INBOX" WRK_NO_SLEEP=1 WRK_FIXTURE_SCENARIO=spawn \
  WRK_FIXTURE_LOG="$TMP/sentinel-env-herdr.log" WRK_FIXTURE_ENV_LOG="$ENV_LOG" \
  WRK_SENTINEL_HERDR_SESSION=host-a WRK_SENTINEL_HERDR_SOCKET=/tmp/host-a.sock \
  WRK_COMPLETION_INTERVAL_S=1 WRK_SENTINEL_LOST_GRACE=0 \
  WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
  WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
  "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture \
  --t T1 --job sentinel-env --owner lane-a >/dev/null
ENV_PIDFILE="$ENV_INBOX/sentinel-env/completion-sentinel.pid"
[[ -s "$ENV_PIDFILE" ]] || fail "spawn must start a completion sentinel once the job is registered"
wait_until 30 grep -q 'HERDR_SESSION=host-a' "$ENV_LOG" ||
  fail "the sentinel must query herdr with the session wrk pinned into it (HERDR_SESSION=host-a), saw: $(tr '\n' '|' <"$ENV_LOG")"
grep -q 'HERDR_SOCKET_PATH=/tmp/host-a.sock' "$ENV_LOG" ||
  fail "the sentinel must query herdr through the socket wrk pinned into it"
kill "$(cat "$ENV_PIDFILE")" 2>/dev/null || true
python3 - "$ENV_INBOX/sentinel-env/events" <<'PY'
import glob, json, sys
spawned = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.spawned.json"))]
assert spawned, "spawn must record a job.spawned receipt"
payload = spawned[-1].get("payload", spawned[-1])
assert payload.get("tab_id") == "w:t1", (
    "job.spawned must record the tab_id `wrk reap` later closes, got %r" % payload.get("tab_id"))
PY
echo "PASS sentinel-inherits-pinned-herdr-session"

# #603: `--keep` puts "keep": true on the job.spawned receipt, and a spawn
# without it writes the exact receipt payload it always did (no keep key, no
# other change).
for keep_case in kept plain; do
  keep_inbox="$TMP/spawn-keep-$keep_case"
  keep_args=()
  [[ "$keep_case" == kept ]] && keep_args=(--keep)
  env -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    HERDR_BIN="$HERDR" SCOPEFUEL_BIN="$SCOPEFUEL" ARBITER_BIN="$ARBITER" \
    ARBITER_INBOX_ROOT="$keep_inbox" WRK_NO_SLEEP=1 WRK_FIXTURE_SCENARIO=spawn \
    WRK_FIXTURE_LOG="$TMP/spawn-keep-herdr.log" WRK_COMPLETION_INTERVAL_S=1 \
    WRK_SCOPEFUEL_LOG="$TMP/scopefuel.log" WRK_REFRESH_LOG="$TMP/refresh.log" \
    WRK_REFRESH_PID_LOG="$TMP/refresh.pids" WRK_REFRESH_TIMEOUT_S=5 \
    "$WRK" spawn -c "$ROOT" -m codex-terra -p "$PROMPT" -w w -l fixture \
    --t T1 --job "spawn-keep-$keep_case" --owner lane-a ${keep_args[@]+"${keep_args[@]}"} >/dev/null ||
    fail "#603: spawn ($keep_case) must succeed"
  kill "$(head -n 1 "$keep_inbox/spawn-keep-$keep_case/completion-sentinel.pid" 2>/dev/null)" 2>/dev/null || true
done
python3 - "$TMP/spawn-keep-kept/spawn-keep-kept/events" "$TMP/spawn-keep-plain/spawn-keep-plain/events" <<'PY'
import glob, json, sys
def receipt(directory):
    paths = sorted(glob.glob(directory + "/*job.spawned.json"))
    assert len(paths) == 1, "exactly one job.spawned receipt, got %r" % paths
    return json.load(open(paths[0]))["payload"]
kept, plain = receipt(sys.argv[1]), receipt(sys.argv[2])
base = {"pane_id": "w:p1", "label": "fixture", "profile": "codex-terra", "workspace": "w", "tab_id": "w:t1",
        "task_id": 76801}
assert plain == base, "a spawn without --keep must write the unchanged receipt, got %r" % plain
assert kept == dict(base, keep=True), "--keep must record keep: true on the receipt, got %r" % kept
assert kept["keep"] is True, "the marker must be the JSON literal true"
PY
grep -q -- '--keep' <<<"$("$WRK" spawn --help)" || fail "#603: spawn --help must document --keep"
# bash 3.2 cannot `source <(...)`, so the two functions go through a file.
sed -n '/^wrk_option_token()/,/^}/p;/^spillover_hub_args()/,/^}/p' "$WRK" >"$TMP/spill-keep-funcs.sh"
spill_keep_err="$(bash -c '. "$1"; spillover_hub_args -m codex-terra -l fixture --keep' _ "$TMP/spill-keep-funcs.sh" 2>&1)" &&
  fail "#603: a hub spill-over must refuse --keep rather than silently drop the marker"
grep -q "option '--keep' is not permitted for a hub spawn" <<<"$spill_keep_err" ||
  fail "#603: the hub spill-over refusal must name --keep: $spill_keep_err"
echo "PASS spawn-keep-marks-receipt"

# ---------------------------------------------------------------------------
# completion idempotency: 같은 report artifact = 같은 round = 레코드 1건
# ---------------------------------------------------------------------------
# 445 재현: `wrk done` 이 쓴 뒤 센티널이 같은 report 를 독립 관측해 두 번째
# job.completed 를 썼다. 억제는 "이 report 내용의 canonical 완료가 이미 있는가"
# (멤버십) 판정이며 건수·임계값이 아니다.
IDEM_INBOX="$TMP/idem-inbox"
idem_arb() { env ARBITER_INBOX_ROOT="$IDEM_INBOX" XDG_DATA_HOME="$TMP/xdg-idem" "$ARBITER" "$@"; }
idem_claim() {
  idem_arb claim --job "$1" --lane lane-a --agent-label wrk-a --t T1 >/dev/null
  idem_arb event --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
panewire_call_count() { grep -cx -- '--' "$1" 2>/dev/null || true; }
sentinel_log_has() { [[ -f "$1" ]] && grep -q "$2" "$1"; }

# IDEM-1 — `wrk done` 재호출은 no-op 이다: 레코드 1건, emit 1회, 두 번째 호출은
# rc=0 + stderr 경고 + 지속 억제 로그. 세 번째 호출도 같다(멤버십, 카운트 아님).
idem_claim idem-double
IDEM_REPORT="$TMP/idem-report.md"
printf 'idem verdict line\n' >"$IDEM_REPORT"
IDEM_PW_LOG="$TMP/idem-panewire.log"
: >"$IDEM_PW_LOG"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" WRK_PANEWIRE_LOG="$IDEM_PW_LOG" \
  "$WRK" 'done' idem-double --report "$IDEM_REPORT" >/dev/null 2>&1
env ARBITER_INBOX_ROOT="$IDEM_INBOX" WRK_PANEWIRE_LOG="$IDEM_PW_LOG" \
  "$WRK" 'done' idem-double --report "$IDEM_REPORT" >"$TMP/idem-dup.out" 2>"$TMP/idem-dup.err"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" WRK_PANEWIRE_LOG="$IDEM_PW_LOG" \
  "$WRK" 'done' idem-double --report "$IDEM_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-double/events" job.completed 1 ||
  fail "a same-report re-completion must not write a second record (got $(event_count "$IDEM_INBOX/idem-double/events" job.completed))"
grep -qxF "OK job=idem-double report=$IDEM_REPORT" "$TMP/idem-dup.out" ||
  fail "a suppressed duplicate still reports the completion as done: $(cat "$TMP/idem-dup.out")"
grep -q 'suppressed duplicate' "$TMP/idem-dup.err" ||
  fail "a suppressed duplicate must warn on stderr: $(cat "$TMP/idem-dup.err")"
grep -q 'suppressed-duplicate' "$IDEM_INBOX/idem-double/completion-suppressed.log" ||
  fail "a suppressed duplicate must leave a durable note in the job directory"
[[ "$(panewire_call_count "$IDEM_PW_LOG")" -eq 1 ]] ||
  fail "the owner lane is notified exactly once per canonical completion (got $(panewire_call_count "$IDEM_PW_LOG") emits)"
echo "PASS completion-done-recall-is-idempotent"

# IDEM-2 — 관측된 445 모양: `wrk done` 가 먼저 쓰고 센티널이 같은 report 를
# 나중에 관측한다. 센티널 판정은 completed 로 기록되지만 쓰기는 억제된다.
idem_claim idem-race
IDEM_RACE_REPORT="$TMP/idem-race-report.md"
printf 'race verdict line\n' >"$IDEM_RACE_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-race --report "$IDEM_RACE_REPORT" >/dev/null 2>&1
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$IDEM_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=30 WRK_COMPLETION_INTERVAL_S=1 \
  "$WRK" sentinel idem-race lane-a wrk-a w1:p1 "$IDEM_RACE_REPORT" >/dev/null 2>&1 &
idem_race_pid=$!
# #770: the sentinel sees the work-terminal record on its first watch and
# exits — it never mints a second completion for an already-done job.
wait_until 30 sentinel_log_has "$IDEM_INBOX/idem-race/completion-sentinel.log" 'action=watch-exit' ||
  fail "a sentinel started after job.completed must notice the terminal and leave"
sleep 1
event_count_is "$IDEM_INBOX/idem-race/events" job.completed 1 ||
  fail "a sentinel observing an already-completed job must not write a second record (got $(event_count "$IDEM_INBOX/idem-race/events" job.completed))"
wait_until 15 bash -c "! kill -0 $idem_race_pid 2>/dev/null" ||
  fail "the sentinel must exit once it sees the job already ended"
wait "$idem_race_pid" 2>/dev/null || true
echo "PASS completion-sentinel-observation-after-done-is-suppressed"

# IDEM-3 — 후속 round 는 별개 1건: report 내용이 바뀌면 새 레코드가 쓰이고 두
# 레코드는 report_sha256 으로 서로 식별된다.
idem_claim idem-rounds
IDEM_ROUNDS_REPORT="$TMP/idem-rounds-report.md"
printf 'round one verdict\n' >"$IDEM_ROUNDS_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-rounds --report "$IDEM_ROUNDS_REPORT" >/dev/null 2>&1
printf 'round two verdict\n' >"$IDEM_ROUNDS_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-rounds --report "$IDEM_ROUNDS_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-rounds/events" job.completed 2 ||
  fail "a new report artifact is a new round and must produce its own record (got $(event_count "$IDEM_INBOX/idem-rounds/events" job.completed))"
python3 - "$IDEM_INBOX/idem-rounds/events" <<'PY'
import glob, hashlib, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.completed.json"))]
assert len(records) == 2, records
digests = {r.get("report_sha256") for r in records}
assert len(digests) == 2, "the two rounds must carry distinct identities: %r" % records
assert digests == {
    hashlib.sha256(b"round one verdict\n").hexdigest(),
    hashlib.sha256(b"round two verdict\n").hexdigest(),
}, digests
PY
echo "PASS completion-distinct-rounds-are-distinct-records"

# IDEM-4 — 센티널은 부분 작성된 report 로 먼저 나가지 않는다: 첫 관측은 pending
# 이고, settle 전에 내용이 바뀌면 최종본만 canonical 이 된다.
IDEM_PARTIAL_INBOX="$TMP/idem-partial-inbox"
IDEM_PARTIAL_REPORT="$TMP/idem-partial-report.md"
printf 'partial draft\n' >"$IDEM_PARTIAL_REPORT"
# The 3s interval leaves a whole settle window between the pending sighting and
# the completion decision — enough to swap in the final content deterministically.
env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$IDEM_PARTIAL_INBOX" \
  WRK_FIXTURE_SCENARIO=sentinel-idle WRK_COMPLETION_TIMEOUT_S=60 WRK_COMPLETION_INTERVAL_S=3 \
  "$WRK" sentinel idem-partial lane-a wrk-a w1:p1 "$IDEM_PARTIAL_REPORT" >/dev/null 2>&1 &
idem_partial_pid=$!
wait_until 30 sentinel_log_has "$IDEM_PARTIAL_INBOX/idem-partial/completion-sentinel.log" 'action=pending' ||
  fail "the first sighting of a report must be a pending observation, not a completion"
event_count_is "$IDEM_PARTIAL_INBOX/idem-partial/events" job.completed 0 ||
  fail "a report observed only once is not yet final and must not be completed"
printf 'partial draft\nfinal verdict line\n' >"$IDEM_PARTIAL_REPORT"
wait_until 30 event_count_is "$IDEM_PARTIAL_INBOX/idem-partial/events" job.completed 1 ||
  fail "once the report settles the sentinel completes exactly once (got $(event_count "$IDEM_PARTIAL_INBOX/idem-partial/events" job.completed))"
python3 - "$IDEM_PARTIAL_INBOX/idem-partial/events" <<'PY'
import glob, hashlib, json, sys
records = [json.load(open(p)) for p in sorted(glob.glob(sys.argv[1] + "/*job.completed.json"))]
assert len(records) == 1, records
assert records[0]["report_sha256"] == hashlib.sha256(b"partial draft\nfinal verdict line\n").hexdigest(), records[0]
assert records[0]["report_last_line"].startswith("final verdict line"), records[0]
PY
kill "$idem_partial_pid" 2>/dev/null || true
wait "$idem_partial_pid" 2>/dev/null || true
echo "PASS completion-sentinel-waits-for-report-to-settle"

# IDEM-5 — 구버전 레코드(report_sha256 없음)는 억제 근거가 되지 않는다.
# identity 부재는 "중복" 이 아니라 "증명 불가" 다 — 어떤 파일시스템 proxy
# (mtime·touch 롤백·cp -p·rsync -a 보존 복사 포함)로도 과거 본문을 증명할 수
# 없으므로 기록 쪽으로 fail-open 한다. 그리고 그 새 형식 레코드는 이후 재호출을
# 정상 억제한다.
idem_claim idem-legacy
IDEM_LEGACY_REPORT="$TMP/idem-legacy-report.md"
printf 'legacy verdict line\n' >"$IDEM_LEGACY_REPORT"
mkdir -p "$IDEM_INBOX/idem-legacy/events"
printf '%s\n' "{\"kind\":\"job.completed\",\"job_id\":\"idem-legacy\",\"owner_lane\":\"lane-a\",\"label\":\"wrk-a\",\"pane_id\":\"w1:p1\",\"host\":\"h\",\"report_path\":\"$IDEM_LEGACY_REPORT\",\"report_last_line\":\"legacy verdict line\",\"epoch\":1}" \
  >"$IDEM_INBOX/idem-legacy/events/00001-job.completed.json"
# mtime 보존 덮어쓰기(tester 의 cp -p/rsync -a 재현 모양)로도 억제되지 않아야 한다.
printf 'new round verdict line\n' >"$IDEM_LEGACY_REPORT"
touch -t 200001010000.00 "$IDEM_LEGACY_REPORT"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-legacy --report "$IDEM_LEGACY_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-legacy/events" job.completed 2 ||
  fail "a rewritten report must record even when its mtime is rolled back below a legacy record (got $(event_count "$IDEM_INBOX/idem-legacy/events" job.completed))"
env ARBITER_INBOX_ROOT="$IDEM_INBOX" "$WRK" 'done' idem-legacy --report "$IDEM_LEGACY_REPORT" >/dev/null 2>&1
event_count_is "$IDEM_INBOX/idem-legacy/events" job.completed 2 ||
  fail "the new-format record must still suppress a same-report recall (got $(event_count "$IDEM_INBOX/idem-legacy/events" job.completed))"
grep -q 'suppressed-duplicate' "$IDEM_INBOX/idem-legacy/completion-suppressed.log" ||
  fail "the suppressed recall on a new-format record must leave a durable note"
echo "PASS completion-legacy-record-never-suppresses"

# ---------------------------------------------------------------------------
# wrk reap: 끝난 pane 회수
# ---------------------------------------------------------------------------
REAP_INBOX="$TMP/reap-inbox"
REAP_LOG="$TMP/reap-herdr.log"
# 종료 이벤트를 한 시간 전으로 새겨 --grace 를 양방향으로 시험한다(ARBITER_TEST_NOW
# 는 arbiter 가 제공하는 주입 지점이다 — 손으로 쓴 이벤트가 아니다).
REAP_TEST_NOW="$(python3 -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)).replace(microsecond=0).isoformat())')"
reap_job() {
  local job="$1" pane="$2" tab="$3" lane="$4" terminal="$5"; shift 5
  local spawned="{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}"
  # tab="" builds the pre-PR shape: a job.spawned receipt with no tab_id at all.
  if [[ -n "$tab" ]]; then
    spawned="{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}"
  fi
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 "$@" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "$spawned" >/dev/null
  if [[ -n "$terminal" ]]; then
    env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind "$terminal" \
      --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  fi
  unset ARBITER_TEST_NOW
}

# A builder job that was released and then reclaimed without --role: the reclaim
# payload carries the default role=worker, so a last-writer-wins role would strip
# the builder marking and hand a live builder pane to reap.
reap_builder_reclaimed_job() {
  local job="$1" pane="$2" lane="$3"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 \
    --role builder --parent-lane lane-p >/dev/null
  # release is what moves a job to `released`; take the exclusive-lease route so
  # the reclaim below is the real arbiter transition, not a hand-written event.
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" lease \
    --job "$job" --resource "$TMP/reap-$job" --kind path >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" release \
    --job "$job" --resource "$TMP/reap-$job" --kind path --force >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim --reclaim-released \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"w1:t7\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.joined \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_job reap-ready w1:p1 w1:t1 lane-a job.completed
reap_job reap-working w1:p2 w1:t2 lane-a job.completed
reap_job reap-open w1:p3 w1:t3 lane-a ''
# The builder sits in the lane under test on purpose: with it in another lane the
# role guard is never reached, because --lane already filtered the job out.
reap_job reap-builder w1:p1 w1:t1 lane-a job.joined --role builder --parent-lane lane-p
reap_job reap-other-lane w1:p1 w1:t1 lane-b job.completed
reap_job reap-shared w1:p4 w1:t4 lane-a job.completed
# Pre-PR shape: no tab_id in job.spawned. The tab has to come from `agent get`,
# and the shared-tab guard must still see it.
reap_job reap-no-tab w1:p5 '' lane-a job.completed
reap_job reap-no-tab-shared w1:p4 '' lane-a job.completed
reap_job reap-lost-only w1:p6 w1:t6 lane-a job.lost
reap_builder_reclaimed_job reap-builder-reclaimed w1:p7 lane-a

# #508 A-1: a job that finished and was then picked up again is live work, even if
# its pane reads idle for a moment (devin/claude panes misreport idle|done during
# long turns). Every event comes from the real arbiter transition.
reap_revived_job() {
  local job="$1" pane="$2" tab="$3" how="$4"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane lane-a --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  case "$how" in
    reclaim)
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" lease \
        --job "$job" --resource "$TMP/reap-$job" --kind path >/dev/null
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" release \
        --job "$job" --resource "$TMP/reap-$job" --kind path --force >/dev/null
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim --reclaim-released \
        --job "$job" --lane lane-a --agent-label "$job" --t T1 >/dev/null
      ;;
    respawn|respawn-done)
      env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
        --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}" >/dev/null
      ;;
  esac
  if [[ "$how" == respawn-done ]]; then
    env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
      --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  fi
  unset ARBITER_TEST_NOW
}
reap_revived_job reap-revived w1:p10 w1:t10 reclaim
reap_revived_job reap-revived-spawn w1:p11 w1:t11 respawn
# Picked up again and then finished again: the latest terminal event wins, so
# this one is reapable — the revive guard must not over-refuse.
reap_revived_job reap-revived-done w1:p12 w1:t12 respawn-done

# #508 A-4: the shape of today's normally finished builder jobs (b505/b448/b449 in
# the live inbox): builder claim → spawned → completed* → joined → completed →
# job.lost. job.lost and quota_pool.* are not revivals; with --include-builders
# in the builder's own lane this job must stay a candidate.
export ARBITER_TEST_NOW="$REAP_TEST_NOW"
env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
  --job reap-b505-shape --lane b505-lane --agent-label reap-b505-shape --t T2 \
  --role builder --parent-lane director-x >/dev/null
env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job reap-b505-shape --kind quota_pool.record \
  --payload-json '{"pool":"claude"}' >/dev/null
env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job reap-b505-shape --kind job.spawned \
  --payload-json '{"owner_lane":"b505-lane","label":"reap-b505-shape","pane_id":"w1:p13","tab_id":"w1:t13"}' >/dev/null
for kind in job.completed job.joined job.completed job.lost; do
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job reap-b505-shape --kind "$kind" \
    --payload-json '{"owner_lane":"b505-lane","parent_lane":"director-x","pane_id":"w1:p13"}' >/dev/null
done
unset ARBITER_TEST_NOW

# #508 tester BLOCKER 1: pane and tab come from the newest job.spawned receipt as a
# unit. A respawn receipt without tab_id must not inherit the previous spawn's tab
# (that closed w1:t1 while the live pane was w1:p9), and a malformed newest receipt
# must not fall back to an older one.
reap_receipts_job() {
  local lane="$1" job="$2"; shift 2
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  local receipt
  for receipt in "$@"; do
    env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
      --payload-json "$receipt" >/dev/null
  done
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"$lane\",\"pane_id\":\"w1:p1\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_receipts_job receipt-lane reap-mixed-receipt \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p14","tab_id":"w1:t14"}' \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p15"}'
reap_receipts_job receipt-lane reap-broken-newest \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p14","tab_id":"w1:t14"}' \
  '{"owner_lane":"receipt-lane","tab_id":"w1:t14"}'
# The recorded tab is not the tab herdr says the pane lives in (pane moved or the
# tab id was reused): neither tab may be closed.
reap_receipts_job receipt-lane reap-moved \
  '{"owner_lane":"receipt-lane","pane_id":"w1:p16","tab_id":"w1:t17"}'
# #508 tester BLOCKER 2: a pane joins the tab between reap's status probe and the
# close. The tab list must be read after the probe, right before the close.
reap_receipts_job race-lane reap-race \
  '{"owner_lane":"race-lane","pane_id":"w1:p18","tab_id":"w1:t18"}'

# Existing inboxes can contain a durable captain payload written before role
# normalization. Reap must protect it exactly like a new builder payload.
reap_legacy_captain_job() {
  local job="$1" pane="$2" lane="$3"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane "$lane" --agent-label "$job" --t T1 >/dev/null
  python3 - "$REAP_INBOX/$job/events/00001-job.claim.json" <<'PY'
import json, sys
path = sys.argv[1]
event = json.load(open(path))
assert set(event) == {"created_at", "job_id", "kind", "payload", "seq"}, event
event["payload"]["role"] = "captain"
event["payload"]["parent_lane"] = "parent-lane"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(event, handle, separators=(",", ":"))
    handle.write("\n")
PY
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"w1:t1\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.joined \
    --payload-json "{\"owner_lane\":\"$lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_legacy_captain_job reap-captain-legacy w1:p1 lane-a

# The `wrk done` that shipped before be4dad1 glued parent_lane and role onto
# pane_id with tabs, and 23 such records sit in the live inbox. The spawn receipt
# stays the source of truth, and no candidate field may carry whitespace.
reap_poisoned_job() {
  local job="$1" spawn_pane="$2"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane lane-a --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"lane-a\",\"label\":\"$job\",\"pane_id\":\"$spawn_pane\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json '{"owner_lane":"lane-a","label":"poisoned","pane_id":"w1:p1\t\tworker"}' >/dev/null
  unset ARBITER_TEST_NOW
}
reap_poisoned_job reap-poisoned w1:p8
reap_poisoned_job reap-poisoned-spawn 'w1:p8\t\tworker'

reap_run() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$REAP_INBOX" \
    WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$REAP_LOG" "$WRK" reap "$@"
}

: >"$REAP_LOG"
dry_out="$(reap_run --lane lane-a)"
grep -q '^would-close job=reap-ready pane=w1:p1 tab=w1:t1 status=idle age=[0-9][0-9]*s$' <<<"$dry_out" ||
  fail "a terminal job whose pane is idle past the grace must be a reap candidate, with its tab and age in their own fields: $dry_out"
# A job.spawned with no tab_id must resolve its tab from `agent get`, and the age
# must never land in the tab field: `herdr tab close <seconds>` closes whatever
# tab happens to carry that number.
grep -q '^would-close job=reap-no-tab pane=w1:p5 tab=w1:t5 status=idle age=[0-9][0-9]*s$' <<<"$dry_out" ||
  fail "a job spawned before tab_id was recorded must resolve its tab through 'agent get', and its age must stay out of the tab field: $dry_out"
grep -q '^would-close job=reap-poisoned pane=w1:p8 tab=w1:t8 status=idle age=[0-9][0-9]*s$' <<<"$dry_out" ||
  fail "the spawn receipt is the source of truth for pane and tab; a completion record poisoned by the old done bug must not reach the candidate row: $dry_out"
grep -q 'tab=worker' <<<"$dry_out" &&
  fail "a value glued onto pane_id by tabs must never be read as a tab id: $dry_out"
grep -q '^skip job=reap-poisoned-spawn reason=malformed-record$' <<<"$dry_out" ||
  fail "when the spawn receipt itself carries whitespace in pane_id the evidence is broken and reap must skip, not guess: $dry_out"
[[ "$(grep -c '^would-close ' <<<"$dry_out")" -eq 4 ]] ||
  fail "only the finished, idle, past-grace jobs may be listed: $dry_out"
grep -q '^skip job=reap-revived reason=reclaimed-after-terminal$' <<<"$dry_out" ||
  fail "#508 A-1: a job reclaimed after its terminal event is live work and must be skipped with its reason: $dry_out"
grep -q '^skip job=reap-revived-spawn reason=reclaimed-after-terminal$' <<<"$dry_out" ||
  fail "#508 A-1: a job spawned again after its terminal event is live work and must be skipped with its reason: $dry_out"
grep -qE '^would-close job=reap-revived(-spawn)? ' <<<"$dry_out" &&
  fail "#508 A-1: a job picked up again after it finished must never be a reap candidate: $dry_out"
grep -q '^would-close job=reap-revived-done pane=w1:p12 tab=w1:t12 status=idle' <<<"$dry_out" ||
  fail "#508 A-4: a job that was picked up again and then finished again is reapable (the latest terminal wins): $dry_out"
grep -q 'reason=status=working' <<<"$dry_out" ||
  fail "a still-working pane must be skipped explicitly, never closed: $dry_out"
grep -q 'reap-open' <<<"$dry_out" &&
  fail "a job with no terminal event must not appear in reap output at all: $dry_out"
grep -q 'reap-lost-only' <<<"$dry_out" &&
  fail "job.lost is not a terminal event: a job the old sentinel wrongly declared lost must never be reaped: $dry_out"
grep -q 'reap-builder' <<<"$dry_out" &&
  fail "a builder pane in the lane under test must still be excluded without --include-builders: $dry_out"
grep -q 'reap-captain-legacy' <<<"$dry_out" &&
  fail "a legacy captain payload must still be excluded without --include-builders: $dry_out"
grep -q 'reap-other-lane' <<<"$dry_out" &&
  fail "--lane must filter by the claim owner_lane: $dry_out"
grep -q 'job=reap-shared .*reason=tab-shared' <<<"$dry_out" ||
  fail "a tab that still holds another pane must be skipped, not closed (closing it kills the sibling pane): $dry_out"
grep -q 'job=reap-no-tab-shared pane=w1:p4 tab=w1:t4 reason=tab-shared' <<<"$dry_out" ||
  fail "the shared-tab guard must also cover a tab resolved through 'agent get', not just one recorded at spawn: $dry_out"
grep -q '^tab close' "$REAP_LOG" &&
  fail "the default run is a dry run: no tab may be closed without --apply"
[[ "$(event_count "$REAP_INBOX/reap-ready/events" job.reaped)" -eq 0 ]] ||
  fail "a dry run must not record job.reaped"
echo "PASS reap-dry-run-lists-only-finished-idle-panes"

# #508 A-2: the shared-tab guard is fail-closed. A tab list that failed, did not
# parse, lacks the tab, or gives a pane_count that is not a confirmed 1 means
# "maybe shared" — never close. Both dry run and --apply must agree.
for mode in fail garbage no-result missing no-count string-count bool-count zero-count duplicate; do
  : >"$REAP_LOG"
  mode_out="$(WRK_FIXTURE_REAP_TABS="$mode" reap_run --lane lane-a)"
  grep -q '^would-close ' <<<"$mode_out" &&
    fail "#508 A-2 ($mode): an unconfirmed pane_count must not produce a candidate: $mode_out"
  grep -q '^skip job=reap-ready pane=w1:p1 tab=w1:t1 reason=tab-count-unknown$' <<<"$mode_out" ||
    fail "#508 A-2 ($mode): an unconfirmed tab must be skipped as tab-count-unknown: $mode_out"
  mode_apply="$(WRK_FIXTURE_REAP_TABS="$mode" reap_run --lane lane-a --apply)"
  grep -q '^tab close' "$REAP_LOG" &&
    fail "#508 A-2 ($mode): --apply must not close any tab when the tab list cannot confirm a single pane: $(cat "$REAP_LOG") / $mode_apply"
  grep -q 'reap: closed 0 tab(s)' <<<"$mode_apply" ||
    fail "#508 A-2 ($mode): --apply must report zero closed tabs: $mode_apply"
done
[[ "$(event_count "$REAP_INBOX/reap-ready/events" job.reaped)" -eq 0 ]] ||
  fail "#508 A-2: no job.reaped may be written while the tab list is untrustworthy"
echo "PASS reap-shared-tab-guard-fails-closed"

# #508 A-3: a lane-less --apply is refused before anything is looked at or closed.
: >"$REAP_LOG"
if nolane_out="$(reap_run --apply 2>&1)"; then
  fail "#508 A-3: --apply without --lane must exit nonzero: $nolane_out"
fi
grep -q -- '--apply requires --lane' <<<"$nolane_out" ||
  fail "#508 A-3: the refusal must say --lane is required: $nolane_out"
[[ ! -s "$REAP_LOG" ]] ||
  fail "#508 A-3: a refused lane-less --apply must not even call herdr: $(cat "$REAP_LOG")"
if find "$REAP_INBOX" -name '*job.reaped.json' | grep -q .; then
  fail "#508 A-3: a refused lane-less --apply must not record job.reaped"
fi
if nolane_builder_out="$(reap_run --apply --include-builders 2>&1)"; then
  fail "#508 A-3: --include-builders must not open a lane-less --apply: $nolane_builder_out"
fi
nolane_dry="$(reap_run)" ||
  fail "#508 A-3: a lane-less dry run is still allowed"
grep -q '^would-close job=reap-ready ' <<<"$nolane_dry" ||
  fail "#508 A-3: a lane-less dry run must still list candidates: $nolane_dry"
grep -q 'Requires --lane' <<<"$("$WRK" reap --help)" ||
  fail "#508: reap --help must document that --apply requires --lane"
grep -q 'reclaimed-after-terminal' <<<"$("$WRK" reap --help)" ||
  fail "#508: reap --help must document the reclaimed-after-terminal rule"
grep -q 'tab-count-unknown' <<<"$("$WRK" reap --help)" ||
  fail "#508: reap --help must document the fail-closed tab rule"
echo "PASS reap-apply-requires-lane"

# #508 A-4: the normally finished builder shape stays reapable (no over-refusal),
# and without --include-builders it stays excluded exactly as before.
b505_default="$(reap_run --lane b505-lane)"
grep -q 'reap-b505-shape' <<<"$b505_default" &&
  fail "#508 A-4: a builder job must still be excluded without --include-builders: $b505_default"
b505_out="$(reap_run --lane b505-lane --include-builders)"
grep -q '^would-close job=reap-b505-shape pane=w1:p13 tab=w1:t13 status=idle' <<<"$b505_out" ||
  fail "#508 A-4: a normally finished builder (… joined → completed → lost) must stay a candidate with --include-builders: $b505_out"
echo "PASS reap-normal-builder-shape-still-reapable"

: >"$REAP_LOG"
receipt_out="$(reap_run --lane receipt-lane --apply)"
grep -q '^closed job=reap-mixed-receipt pane=w1:p15 tab=w1:t15 ' <<<"$receipt_out" ||
  fail "#508 R1: a respawn receipt without tab_id must resolve the live pane's own tab, not inherit the older spawn's tab: $receipt_out"
grep -q '^tab close w1:t14$' "$REAP_LOG" &&
  fail "#508 R1: the previous spawn's tab (w1:t14) must never be closed for a newer pane: $(cat "$REAP_LOG")"
grep -q '^skip job=reap-broken-newest reason=malformed-record$' <<<"$receipt_out" ||
  fail "#508 R1: a malformed newest receipt must be skipped, never patched from an older receipt: $receipt_out"
grep -q '^skip job=reap-moved pane=w1:p16 tab=w1:t17 reason=tab-mismatch(pane-in=w1:t16)$' <<<"$receipt_out" ||
  fail "#508 R1: a recorded tab that is not the pane's current tab must be skipped as tab-mismatch: $receipt_out"
grep -qE '^tab close w1:t1[67]$' "$REAP_LOG" &&
  fail "#508 R1: neither the recorded nor the actual tab of a moved pane may be closed: $(cat "$REAP_LOG")"
[[ "$(grep -c '^tab close ' "$REAP_LOG")" -eq 1 ]] ||
  fail "#508 R1: only the mixed-receipt job's own tab may be closed: $(cat "$REAP_LOG")"
echo "PASS reap-newest-receipt-and-tab-mismatch"

: >"$REAP_LOG"
race_out="$(WRK_FIXTURE_REAP_TABS=race reap_run --lane race-lane --apply)"
grep -q '^tab close' "$REAP_LOG" &&
  fail "#508 R1: a pane that joined the tab after the status probe must stop the close: $(cat "$REAP_LOG") / $race_out"
grep -q '^skip job=reap-race pane=w1:p18 tab=w1:t18 reason=tab-shared(panes=2)$' <<<"$race_out" ||
  fail "#508 R1: the tab list read right before the close must see the joined pane: $race_out"
python3 - "$REAP_LOG" <<'PY'
import sys
lines = [line.strip() for line in open(sys.argv[1])]
probe = lines.index("agent get w1:p18")
listing = [i for i, line in enumerate(lines) if line == "tab list"]
assert listing and max(listing) > probe, (
    "#508 R1: the tab list deciding the close must be read after the pane probe: %r" % lines)
PY
echo "PASS reap-tab-list-reread-before-close"

grep -q 'reap: 0 candidate' <<<"$(reap_run --lane lane-a --grace 2h)" ||
  fail "a terminal event younger than --grace is not yet reapable"
if reap_run --lane lane-a --grace 10min >/dev/null 2>&1; then
  fail "an unparsable --grace must fail loudly; falling back to 0 would reap with no grace at all"
fi
builder_out="$(reap_run --lane lane-a --include-builders)"
python3 - "$builder_out" <<'PY'
import sys
assert "would-close job=reap-builder " in sys.argv[1], sys.argv[1]
assert "would-close job=reap-captain-legacy " in sys.argv[1], sys.argv[1]
PY
grep -q 'would-close job=reap-builder ' <<<"$builder_out" ||
  fail "--include-builders must let a finished builder pane in this lane be reaped: $builder_out"
grep -q 'would-close job=reap-builder-reclaimed ' <<<"$builder_out" ||
  fail "--include-builders must reach the reclaimed builder too: $builder_out"
grep -q 'would-close job=reap-captain-legacy ' <<<"$builder_out" ||
  fail "--include-builders must include a legacy captain payload: $builder_out"
captain_out="$(reap_run --lane lane-a --include-captains)"
grep -q 'would-close job=reap-builder ' <<<"$captain_out" ||
  fail "--include-captains must remain an alias for --include-builders: $captain_out"
grep -q 'would-close job=reap-captain-legacy ' <<<"$captain_out" ||
  fail "--include-captains must include a legacy captain payload: $captain_out"
echo "PASS reap-builder-and-captain-alias-filters"

: >"$REAP_LOG"
apply_out="$(reap_run --lane lane-a --apply)"
grep -q '^closed job=reap-ready pane=w1:p1 tab=w1:t1 status=idle' <<<"$apply_out" ||
  fail "--apply must close the candidate tab: $apply_out"
grep -q '^closed job=reap-no-tab pane=w1:p5 tab=w1:t5 status=idle' <<<"$apply_out" ||
  fail "--apply must close the tab it resolved through 'agent get', by tab id: $apply_out"
grep -q '^closed job=reap-poisoned pane=w1:p8 tab=w1:t8 status=idle' <<<"$apply_out" ||
  fail "--apply must close the tab from the spawn receipt, not one read out of a poisoned record: $apply_out"
[[ "$(grep -c '^tab close ' "$REAP_LOG")" -eq 4 ]] ||
  fail "only the four candidates' tabs may be closed: $(cat "$REAP_LOG")"
grep -qE '^tab close w1:t1[01]$' "$REAP_LOG" &&
  fail "#508 A-1: --apply must never close the tab of a job picked up again after it finished: $(cat "$REAP_LOG")"
[[ "$(event_count "$REAP_INBOX/reap-revived/events" job.reaped)" -eq 0 ]] ||
  fail "#508 A-1: a reclaimed-after-terminal job must not be recorded as reaped"
grep -q 'tab close worker' "$REAP_LOG" &&
  fail "reap must never pass a role name to herdr tab close: $(cat "$REAP_LOG")"
grep -q '^tab close w1:t1$' "$REAP_LOG" ||
  fail "reap must close the tab_id recorded at spawn: $(cat "$REAP_LOG")"
grep -q '^tab close w1:t5$' "$REAP_LOG" ||
  fail "reap must close a resolved tab by its id, never by an age or a number: $(cat "$REAP_LOG")"
grep -qE '^tab close [0-9]+$' "$REAP_LOG" &&
  fail "a bare number is never a tab id; that is a live tab's number: $(cat "$REAP_LOG")"
grep -q 'tab close w1:t7' "$REAP_LOG" &&
  fail "a builder tab must never be closed by a plain --apply run: $(cat "$REAP_LOG")"
[[ "$(event_count "$REAP_INBOX/reap-builder-reclaimed/events" job.reaped)" -eq 0 ]] ||
  fail "a builder that was released and reclaimed without --role keeps its builder marking"
[[ "$(event_count "$REAP_INBOX/reap-builder/events" job.reaped)" -eq 0 ]] ||
  fail "a builder job in the reaped lane must not be reaped without --include-builders"
[[ "$(event_count "$REAP_INBOX/reap-captain-legacy/events" job.reaped)" -eq 0 ]] ||
  fail "a legacy captain payload in the reaped lane must not be reaped without --include-builders"
python3 - "$REAP_INBOX/reap-no-tab/events" <<'PY'
import glob, json, sys
event = json.load(open(sorted(glob.glob(sys.argv[1] + "/*job.reaped.json"))[0]))
assert event.get("tab_id") == "w1:t5", (
    "job.reaped must record the tab id that was actually closed, not an age: %r" % event)
PY
python3 - "$REAP_INBOX/reap-ready/events" <<'PY'
import glob, json, sys
paths = sorted(glob.glob(sys.argv[1] + "/*job.reaped.json"))
assert len(paths) == 1, "a closed job records exactly one flat job.reaped event, got %d" % len(paths)
event = json.load(open(paths[0]))
assert event.get("kind") == "job.reaped", event
assert event.get("pane_id") == "w1:p1", "job.reaped must record the reaped pane_id: %r" % event
assert event.get("tab_id") == "w1:t1", "job.reaped must record the closed tab_id: %r" % event
assert event.get("at"), "job.reaped must record when the tab was closed: %r" % event
PY
grep -q 'reap: 0 candidate' <<<"$(reap_run --lane lane-a)" ||
  fail "an already reaped job must never be offered again"
echo "PASS reap-apply-closes-tab-and-records-job-reaped"

# #603: a protected job (`wrk spawn --keep` → "keep": true on its job.spawned
# receipt) is never closed. It is reported once it would otherwise have been a
# candidate, and only a JSON true counts. The unprotected control shares the
# lane, pane state and age, so the skip is caused by the marker alone.
KEEP_REAP_INBOX="$TMP/reap-keep-inbox"
reap_keep_job() {
  local job="$1" pane="$2" tab="$3" receipt_extra="$4" now="$5"
  export ARBITER_TEST_NOW="$now"
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane keep-lane --agent-label "$job" --t T1 >/dev/null
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"$receipt_extra}" >/dev/null
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
KEEP_FRESH_NOW="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat())')"
reap_keep_job reap-kept w1:p1 w1:t1 ',"keep":true' "$REAP_TEST_NOW"
reap_keep_job reap-kept-string w1:p5 w1:t5 ',"keep":"true"' "$REAP_TEST_NOW"
reap_keep_job reap-kept-fresh w1:p3 w1:t3 ',"keep":true' "$KEEP_FRESH_NOW"
reap_keep_job reap-unkept w1:p6 w1:t6 '' "$REAP_TEST_NOW"
# The marker is sticky on claims and reclaims too. arbiter never writes it
# there, so the fixture edits the real claim/reclaim event, like the legacy
# captain case above.
reap_keep_marked_event_job() {
  local job="$1" pane="$2" tab="$3" marked_kind="$4"
  export ARBITER_TEST_NOW="$REAP_TEST_NOW"
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" claim \
    --job "$job" --lane keep-lane --agent-label "$job" --t T1 >/dev/null
  if [[ "$marked_kind" == job.reclaim ]]; then
    env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" lease \
      --job "$job" --resource "$TMP/reap-$job" --kind path >/dev/null
    env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" release \
      --job "$job" --resource "$TMP/reap-$job" --kind path --force >/dev/null
    env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" claim --reclaim-released \
      --job "$job" --lane keep-lane --agent-label "$job" --t T1 >/dev/null
  fi
  python3 - "$KEEP_REAP_INBOX/$job/events" "$marked_kind" <<'PY'
import glob, json, sys
events, kind = sys.argv[1:3]
paths = sorted(glob.glob(events + "/*-" + kind + ".json"))
assert len(paths) == 1, (kind, paths)
event = json.load(open(paths[0]))
event["payload"]["keep"] = True
with open(paths[0], "w", encoding="utf-8") as handle:
    json.dump(event, handle, separators=(",", ":"))
    handle.write("\n")
PY
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.spawned \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\",\"tab_id\":\"$tab\"}" >/dev/null
  env ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" "$ARBITER" event --job "$job" --kind job.completed \
    --payload-json "{\"owner_lane\":\"keep-lane\",\"label\":\"$job\",\"pane_id\":\"$pane\"}" >/dev/null
  unset ARBITER_TEST_NOW
}
reap_keep_marked_event_job reap-kept-claim w1:p7 w1:t7 job.claim
reap_keep_marked_event_job reap-kept-reclaim w1:p8 w1:t8 job.reclaim
keep_reap_run() {
  env HERDR_BIN="$HERDR" ARBITER_INBOX_ROOT="$KEEP_REAP_INBOX" \
    WRK_FIXTURE_SCENARIO=reap WRK_FIXTURE_LOG="$REAP_LOG" "$WRK" reap "$@"
}
: >"$REAP_LOG"
keep_out="$(keep_reap_run --lane keep-lane)"
grep -q '^skip job=reap-kept reason=protected$' <<<"$keep_out" ||
  fail "#603: a kept job past its grace must be skipped with reason=protected: $keep_out"
grep -q '^would-close job=reap-kept ' <<<"$keep_out" &&
  fail "#603: a kept job must never be a reap candidate: $keep_out"
grep -q '^would-close job=reap-unkept pane=w1:p6 tab=w1:t6 status=idle' <<<"$keep_out" ||
  fail "#603: the unprotected control in the same lane must stay a candidate: $keep_out"
grep -q '^would-close job=reap-kept-string pane=w1:p5 tab=w1:t5 status=idle' <<<"$keep_out" ||
  fail "#603: only a JSON true protects; the string \"true\" is not a marker: $keep_out"
grep -q 'reap-kept-fresh' <<<"$keep_out" &&
  fail "#603: a kept job still inside its grace stays silent like any other: $keep_out"
for kept_job in reap-kept-claim reap-kept-reclaim; do
  grep -q "^skip job=$kept_job reason=protected$" <<<"$keep_out" ||
    fail "#603: keep on a claim or reclaim protects the job too ($kept_job): $keep_out"
done
: >"$REAP_LOG"
keep_apply_out="$(keep_reap_run --lane keep-lane --apply)"
grep -q '^tab close w1:t1$' "$REAP_LOG" &&
  fail "#603: --apply must never close a kept job's tab: $(cat "$REAP_LOG")"
for kept_job in reap-kept reap-kept-claim reap-kept-reclaim; do
  [[ "$(event_count "$KEEP_REAP_INBOX/$kept_job/events" job.reaped)" -eq 0 ]] ||
    fail "#603: a kept job must not be recorded as reaped ($kept_job)"
done
grep -qE '^tab close w1:t[78]$' "$REAP_LOG" &&
  fail "#603: --apply must never close a tab whose job was kept by its claim or reclaim: $(cat "$REAP_LOG")"
grep -q '^closed job=reap-unkept ' <<<"$keep_apply_out" ||
  fail "#603: --apply must still close the unprotected control: $keep_apply_out"
echo "PASS reap-skips-kept-jobs"

# ── #499: done/escalate/joined hand over to `panewire job` only when it exists ──
# Deployment order must not matter: with a panewire that lacks the command (or
# no panewire at all) wrk behaves exactly as before, and whichever path runs,
# each event is written once — never zero times, never twice.
J499_INBOX="$TMP/j499-inbox"
J499_REPORT="$TMP/j499-report.md"
printf 'j499 report line\n' >"$J499_REPORT"
j499_claim() {
  env ARBITER_INBOX_ROOT="$J499_INBOX" XDG_DATA_HOME="$TMP/xdg-j499" "$ARBITER" claim \
    --job "$1" --lane lane-a --agent-label wrk-a --t T1 "${@:2}" >/dev/null
  env ARBITER_INBOX_ROOT="$J499_INBOX" XDG_DATA_HOME="$TMP/xdg-j499" "$ARBITER" event \
    --job "$1" --kind job.spawned \
    --payload-json '{"owner_lane":"lane-a","label":"wrk-a","pane_id":"w1:p1"}' >/dev/null
}
j499_run() {  # j499_run DELEGATE JOB_MODE TAG wrk-args...
  local delegate="$1" mode="$2" tag="$3"
  shift 3
  env WRK_JOB_DELEGATE="$delegate" ARBITER_INBOX_ROOT="$J499_INBOX" HOSTNAME=fixture-host \
    WRK_PANEWIRE_JOB="$mode" WRK_PANEWIRE_LOG="$TMP/j499-$tag-emit.log" \
    WRK_PANEWIRE_JOB_LOG="$TMP/j499-$tag-job.log" "$WRK" "$@"
}
j499_lines() { if [[ -f "$1" ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }
j499_calls() { if [[ -f "$1" ]]; then grep -cx -- '--' "$1" || true; else echo 0; fi; }

# present: wrk hands the exact arguments over and writes nothing of its own.
j499_claim j499-worker
j499_claim j499-builder --role builder --parent-lane parent-a
out="$(j499_run 1 present present 'done' j499-worker --report "$J499_REPORT")"
[[ "$out" == "fixture job done j499-worker --report $J499_REPORT" ]] ||
  fail "delegated done must pass panewire's stdout through: $out"
j499_run 1 present present escalate j499-builder --question 'two  spaces "and" quotes' >/dev/null
j499_run 1 present present joined j499-builder --pr https://example.invalid/pr/9 --head beef \
  --report "$J499_REPORT" >/dev/null
diff "$TMP/j499-present-job.log" <(printf '%s\n' \
  "HOSTNAME=fixture-host [done] [j499-worker] [--report] [$J499_REPORT]" \
  'HOSTNAME=fixture-host [escalate] [j499-builder] [--question] [two  spaces "and" quotes]' \
  "HOSTNAME=fixture-host [joined] [j499-builder] [--pr] [https://example.invalid/pr/9] [--head] [beef] [--report] [$J499_REPORT]") ||
  fail "delegation must hand panewire job the unmodified arguments"
[[ "$(event_count "$J499_INBOX/j499-worker/events" job.completed)" == 1 ]] ||
  fail "delegated done must leave exactly one record (the delegated binary's own)"
grep -l '"via": "fixture-job-done"' "$J499_INBOX/j499-worker/events"/*-job.completed.json >/dev/null ||
  fail "the delegated record must be panewire's own write, not wrk's"
[[ "$(event_count "$J499_INBOX/j499-builder/events" job.escalate)" == 0 ]] ||
  fail "delegated escalate must not also write wrk's record"
[[ "$(event_count "$J499_INBOX/j499-builder/events" job.joined)" == 0 ]] ||
  fail "delegated joined must not also write wrk's record"
[[ "$(j499_calls "$TMP/j499-present-emit.log")" == 0 ]] ||
  fail "delegated commands must not also run wrk's emit"
# A failing delegated call falls back to wrk's own write path (#770 tester
# BLOCKER 1): the terminal record must not ride down with panewire's rc.
# Fresh job — j499-worker already holds the delegated round-1 record, so an
# identical re-done would be suppressed before delegation ever runs (#1014).
j499_claim j499-rc-worker
rc=0
out="$(WRK_PANEWIRE_JOB_RC=7 j499_run 1 present rc 'done' j499-rc-worker --report "$J499_REPORT" 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "a failing delegated done must fall back to wrk's own path, got rc=$rc"
printf '%s\n' "$out" | grep -q 'delegation failed' ||
  fail "the fallback must warn on stderr: $out"
[[ "$(event_count "$J499_INBOX/j499-rc-worker/events" job.completed)" == 1 &&
   "$(j499_calls "$TMP/j499-rc-emit.log")" == 1 ]] ||
  fail "the fallback must write and emit the record exactly once, locally"
# Help stays wrk's own even when panewire has the command.
j499_run 1 present help escalate --help | grep -q '^Usage: wrk escalate JOB' ||
  fail "escalate --help must stay local"
[[ "$(j499_lines "$TMP/j499-help-job.log")" == 0 ]] || fail "escalate --help must not delegate"
echo "PASS j499-delegates-once-to-panewire-job"

# absent / garbage / forced off: wrk's own path, exactly one record and
# one emit per command, zero delegated calls.
for mode in absent garbage off; do
  job_mode="$mode" delegate=1
  if [[ "$mode" == off ]]; then job_mode=present delegate=0; fi
  worker="j499-$mode-worker" builder="j499-$mode-builder"
  j499_claim "$worker"
  j499_claim "$builder" --role builder --parent-lane parent-a
  out="$(j499_run "$delegate" "$job_mode" "$mode" 'done' "$worker" --report "$J499_REPORT")"
  [[ "$out" == "OK job=$worker report=$J499_REPORT" ]] || fail "$mode: done output changed: $out"
  out="$(j499_run "$delegate" "$job_mode" "$mode" escalate "$builder" --question 'fallback question')"
  [[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.escalate" ]] || fail "$mode: escalate output changed: $out"
  out="$(j499_run "$delegate" "$job_mode" "$mode" joined "$builder" --pr https://example.invalid/pr/8 \
    --head f00d --report "$J499_REPORT")"
  [[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.joined pr=https://example.invalid/pr/8 head=f00d report=$J499_REPORT" ]] ||
    fail "$mode: joined output changed: $out"
  [[ "$(event_count "$J499_INBOX/$worker/events" job.completed)" == 1 ]] || fail "$mode: done must write exactly one record"
  [[ "$(event_count "$J499_INBOX/$builder/events" job.escalate)" == 1 ]] || fail "$mode: escalate must write exactly one record"
  [[ "$(event_count "$J499_INBOX/$builder/events" job.joined)" == 1 ]] || fail "$mode: joined must write exactly one record"
  [[ "$(j499_calls "$TMP/j499-$mode-emit.log")" == 3 ]] || fail "$mode: each command must emit exactly once"
  [[ "$(j499_lines "$TMP/j499-$mode-job.log")" == 0 ]] || fail "$mode: nothing may be delegated"
  [[ ! -e "$J499_INBOX/$worker/emit-failures.log" ]] || fail "$mode: a clean fallback must leave no emit failure"
  PYTHONPATH="$TMP" python3 - "$TMP/j499-$mode-emit.log" "$J499_INBOX/$worker/events" "$J499_INBOX/$builder/events" <<'PY'
import sys
import r20_emit as helper
log, worker, builder = sys.argv[1:]
done_call, escalate_call, joined_call = helper.calls(log)
helper.assert_matches_record(done_call, helper.record(worker, "job.completed"))
helper.assert_matches_record(escalate_call, helper.record(builder, "job.escalate"))
helper.assert_matches_record(joined_call, helper.record(builder, "job.joined"))
PY
done
echo "PASS j499-falls-back-to-own-path-without-panewire-job"

# hang: the fixture sleeps inside `panewire job probe`, so the probe is killed
# by WRK_JOB_DELEGATE_TIMEOUT_S and the invocation marks panewire wedged. The
# local path still writes exactly one record per command, but emit must not
# re-enter the wedged binary: zero emit calls, one delegate_timeout marker
# per skipped emit, and no delegated job call ever reaches the fixture log.
mode=hang
worker="j499-$mode-worker" builder="j499-$mode-builder"
j499_claim "$worker"
j499_claim "$builder" --role builder --parent-lane parent-a
out="$(WRK_JOB_DELEGATE_TIMEOUT_S=2 j499_run 1 hang hang 'done' "$worker" --report "$J499_REPORT")"
[[ "$out" == "OK job=$worker report=$J499_REPORT" ]] || fail "hang: done output changed: $out"
out="$(WRK_JOB_DELEGATE_TIMEOUT_S=2 j499_run 1 hang hang escalate "$builder" --question 'fallback question')"
[[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.escalate" ]] || fail "hang: escalate output changed: $out"
out="$(WRK_JOB_DELEGATE_TIMEOUT_S=2 j499_run 1 hang hang joined "$builder" --pr https://example.invalid/pr/8 \
  --head f00d --report "$J499_REPORT")"
[[ "$out" == "OK job=$builder owner_lane=lane-a kind=job.joined pr=https://example.invalid/pr/8 head=f00d report=$J499_REPORT" ]] ||
  fail "hang: joined output changed: $out"
[[ "$(event_count "$J499_INBOX/$worker/events" job.completed)" == 1 ]] || fail "hang: done must write exactly one record"
[[ "$(event_count "$J499_INBOX/$builder/events" job.escalate)" == 1 ]] || fail "hang: escalate must write exactly one record"
[[ "$(event_count "$J499_INBOX/$builder/events" job.joined)" == 1 ]] || fail "hang: joined must write exactly one record"
[[ "$(j499_calls "$TMP/j499-hang-emit.log")" == 0 ]] || fail "hang: emit must not re-enter the wedged panewire"
[[ "$(j499_lines "$TMP/j499-hang-job.log")" == 0 ]] || fail "hang: nothing may be delegated past the hung probe"
grep -Eq '^[0-9TZ:-]+ kind=job.completed rc=delegate_timeout$' "$J499_INBOX/$worker/emit-failures.log" ||
  fail "hang: done must mark the skipped emit as delegate_timeout"
[[ "$(grep -c 'rc=delegate_timeout$' "$J499_INBOX/$builder/emit-failures.log")" == 2 ]] ||
  fail "hang: escalate+joined must each mark a delegate_timeout"
echo "PASS j499-hang-wedges-panewire-and-skips-emit"

# no binary: wrk's own record, and the missing emit is marked exactly as before.
j499_claim j499-nobin-worker
out="$(env ARBITER_INBOX_ROOT="$J499_INBOX" HOSTNAME=fixture-host PANEWIRE_BIN="$TMP/no-such-panewire" \
  "$WRK" 'done' j499-nobin-worker --report "$J499_REPORT" 2>/dev/null)"
[[ "$out" == "OK job=j499-nobin-worker report=$J499_REPORT" ]] || fail "no panewire: done output changed: $out"
[[ "$(event_count "$J499_INBOX/j499-nobin-worker/events" job.completed)" == 1 ]] ||
  fail "no panewire: done must write exactly one record"
grep -Eq '^[0-9TZ:-]+ kind=job.completed rc=not_found$' "$J499_INBOX/j499-nobin-worker/emit-failures.log" ||
  fail "no panewire: the missing emit must still be marked"
echo "PASS j499-no-panewire-binary-keeps-own-path"

grep -q "for tool in \"\$REPO_DIR\"/bin/\\*" "$ROOT/install.sh"

# ROB-1190 ④-3: scopefuel 이 추천하는 모든 프로필 ⊆ wrk 가 띄울 수 있는 프로필.
# WRK_TEST_SCOPEFUEL_SRC 로 scopefuel worktree 경로를 주면 uv run 으로 실제 GRADE_TABLE 을
# 조회해 대조한다(둘 다 로컬에 있을 때만 — 없으면 스킵, CI 이식성 유지).
if [[ -n "${WRK_TEST_SCOPEFUEL_SRC:-}" ]] && command -v uv >/dev/null 2>&1; then
  scopefuel_profiles="$(cd "$WRK_TEST_SCOPEFUEL_SRC" && uv run scopefuel --list-recommend-profiles 2>/dev/null)"
  wrk_profiles="$("$WRK" profiles)"
  missing=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    if ! grep -qx "$p" <<<"$wrk_profiles"; then
      echo "cross-check FAIL: scopefuel recommends '$p' but wrk cannot spawn it" >&2
      missing=1
    fi
  done <<<"$scopefuel_profiles"
  [[ "$missing" -eq 0 ]]
  echo "PASS scopefuel-recommends-subset-of-wrk-profiles"
else
  echo "SKIP scopefuel⊆wrk cross-check (set WRK_TEST_SCOPEFUEL_SRC + uv to enable)"
fi

# ---------------------------------------------------------------------------
# wrk heavy — per-host serialization lock for >1min local runs (#721)
# ---------------------------------------------------------------------------
HEAVY_LOCK="$TMP/heavy.lock"
HEAVY_LOAD="$TMP/heavy-load"
printf '0\n' >"$HEAVY_LOAD"
export WRK_HEAVY_LOCK="$HEAVY_LOCK" WRK_HEAVY_LOAD_FILE="$HEAVY_LOAD" \
  WRK_HEAVY_LOG="$TMP/heavy.log"

heavy_status_has_waiter() { "$WRK" heavy status | grep -q 'waiter pid='; }
pid_dead() { ! kill -0 "$1" 2>/dev/null; }
heavy_dead() { wait_until 10 pid_dead "$1"; }
heavy_touch() { printf 'touch "%s"\n' "$1" >"$2"; }

# Small command scripts stand in for real suites (sleep marks the "hold").
# held-start is touched only after the holder has the lock and its command
# has started — waiting on it removes the launch race (no sleep-N guessing).
printf 'touch "%s"\nsleep 2\ntouch "%s"\n' "$TMP/heavy-held-start" "$TMP/heavy-holder-done" >"$TMP/holder2.sh"
printf 'touch "%s"\nsleep 6\n' "$TMP/heavy-stat-held" >"$TMP/holder6.sh"
printf 'touch "%s"\nsleep 8\n' "$TMP/heavy-cap-held" >"$TMP/holder8.sh"
printf 'sleep 60 &\necho $! > "%s"\n' "$TMP/heavy-orphan.pid" >"$TMP/orphan.sh"
printf 'ps -o nice= -p $$ | tr -d " " > "%s"\n' "$TMP/heavy-nice.val" >"$TMP/nice.sh"
heavy_touch "$TMP/heavy-cap-ran" "$TMP/touch-cap.sh"
heavy_touch "$TMP/heavy-load-ran" "$TMP/touch-load.sh"
heavy_touch "$TMP/heavy-load-ran2" "$TMP/touch-load2.sh"
heavy_touch "$TMP/heavy-load-ran3" "$TMP/touch-load3.sh"

expect_exit 0 "$WRK" heavy --help
expect_exit 2 "$WRK" heavy
expect_exit 2 "$WRK" heavy no-double-dash
expect_exit 2 "$WRK" heavy --
expect_exit 2 "$WRK" heavy status extra
expect_exit 0 "$WRK" heavy status
"$WRK" heavy status | grep -q 'holder none' || fail "free lock must report 'holder none'"
"$WRK" heavy -- true || fail "simple run must succeed"
expect_exit 1 "$WRK" heavy -- false
expect_exit 127 "$WRK" heavy -- definitely-not-a-real-binary-721

# the default lock path resolves to the per-host /tmp file — asserted
# through `wrk heavy status` output only. Never rm the real lock file or
# its .waiters dir: other sessions serialize on that inode, and unlinking
# it mid-hold splits the host queue (r2 finding N1).
default_lock="$(python3 -c 'import socket; print("/tmp/wrk-heavy-%s.lock" % socket.gethostname())')"
env -u WRK_HEAVY_LOCK "$WRK" heavy status | grep -qF "lock $default_lock" ||
  fail "default lock path not used"

# the command runs under nice -n 10 — asserted relative to this suite's own
# nice value so the check still has teeth when the suite itself is already
# niced by an outer wrk heavy (dogfood run). The probe gates hosts where
# nice is inert (some CI macOS images report 0 for a niced child).
suite_nice="$(ps -o nice= -p "$$" | tr -d ' ')"
nice_probe="$(nice -n 10 sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
nice_ceiling="$(nice -n 40 sh -c 'ps -o nice= -p $$' 2>/dev/null | tr -d ' ')"
if [[ "$suite_nice" =~ ^[0-9]+$ && "$nice_probe" =~ ^[0-9]+$ &&
      "$nice_ceiling" =~ ^[0-9]+$ && "$nice_probe" -gt "$suite_nice" ]]; then
  expected=$(( suite_nice + 10 ))
  (( expected > nice_ceiling )) && expected="$nice_ceiling"
  "$WRK" heavy -- bash "$TMP/nice.sh" || fail "nice check run failed"
  nice_val=""
  read -r nice_val <"$TMP/heavy-nice.val" || true
  [[ "$nice_val" =~ ^[0-9]+$ && "$nice_val" -ge "$expected" ]] ||
    fail "command not under nice -n 10 (suite=$suite_nice got=$nice_val want>=$expected)"
else
  echo "SKIP nice assertion: nice(1) has no observable effect here"
fi

# a released lock leaves no stale holder record behind.
[[ ! -s "$HEAVY_LOCK" ]] || fail "released lock file still carries holder info"
echo "PASS heavy-basic-contract"

# holder + waiter: the waiter's command runs only after the holder releases.
"$WRK" heavy -- bash "$TMP/holder2.sh" &
holder_job=$!
wait_until 10 test -f "$TMP/heavy-held-start" || fail "holder never took the lock"
"$WRK" heavy -- test -f "$TMP/heavy-holder-done" ||
  fail "waiter ran before the holder released the lock"
wait "$holder_job" || fail "holder run failed"
echo "PASS heavy-serializes-holder-and-waiter"

# status shows the holder and the queued waiters — including a waiter whose
# own command text contains a pid= token (must not be mistaken for dead).
"$WRK" heavy -- bash "$TMP/holder6.sh" &
holder_job=$!
wait_until 10 test -f "$TMP/heavy-stat-held" || fail "status holder never started"
out="$("$WRK" heavy status)"
grep -q 'holder pid=' <<<"$out" || fail "status must show the holder: $out"
grep -q 'cmd=' <<<"$out" || fail "status must show the holder command: $out"
"$WRK" heavy -- env pid=999999 true &
waiter_job=$!
wait_until 10 heavy_status_has_waiter || fail "status never showed the waiter"
wait "$waiter_job" || fail "queued waiter never ran"
wait "$holder_job" || fail "holder run failed"
out="$("$WRK" heavy status)"
grep -q 'holder none' <<<"$out" || fail "status must show a free lock after release: $out"
echo "PASS heavy-status-shows-holder-and-waiters"

# a nested wrk heavy on the same lock must not deadlock against itself — it
# runs the inner command directly (the outer already serializes the host).
rc=0
out="$(WRK_HEAVY_WAIT_CAP=5 "$WRK" heavy -- "$WRK" heavy -- true 2>&1)" || rc=$?
[[ "$rc" == 0 ]] || fail "nested wrk heavy must not block to the cap, got rc=$rc"
grep -q 'already holding' <<<"$out" || fail "nested run must say it skipped the lock: $out"
echo "PASS heavy-nested-run-does-not-deadlock"

# a stale or forged WRK_HEAVY_HELD must not bypass the lock — bypass needs a
# pid that is alive AND recorded as the holder in the lock file (an orphan
# that outlives its holder still carries the env var).
out="$(WRK_HEAVY_HELD="$HEAVY_LOCK:999999" "$WRK" heavy -- true 2>&1)"
if grep -q 'already holding' <<<"$out"; then
  fail "dead-pid WRK_HEAVY_HELD bypassed the lock"
fi
out="$(WRK_HEAVY_HELD="$HEAVY_LOCK:$$" "$WRK" heavy -- true 2>&1)"
if grep -q 'already holding' <<<"$out"; then
  fail "live non-holder WRK_HEAVY_HELD bypassed the lock"
fi
echo "PASS heavy-held-env-needs-live-holder"

# a command killed by a signal maps to 128+sig (TERM → 143).
expect_exit 143 "$WRK" heavy -- sh -c 'kill -TERM $$'
echo "PASS heavy-signal-exit-mapped"

# wait cap: a waiter gives up with rc 75 once the cap is exceeded, without
# running its command.
"$WRK" heavy -- bash "$TMP/holder8.sh" &
holder_job=$!
wait_until 10 test -f "$TMP/heavy-cap-held" || fail "cap holder never started"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- bash "$TMP/touch-cap.sh" 2>&1)" || rc=$?
[[ "$rc" == 75 ]] || fail "wait cap must exit 75, got rc=$rc"
grep -q 'wait cap' <<<"$out" || fail "cap expiry must say why: $out"
[[ ! -e "$TMP/heavy-cap-ran" ]] || fail "command ran despite the wait cap"
wait "$holder_job" || fail "cap holder run failed"
echo "PASS heavy-wait-cap-exits-75"

# the slot fd is deliberately inherited (nested-proof): an orphaned child
# keeps the slot while it lives — resource accounting tracks the work tree,
# not the wrapper — and releases it the moment the orphan dies.
"$WRK" heavy -- bash "$TMP/orphan.sh" || fail "orphan-spawning run failed"
read -r orphan_pid <"$TMP/heavy-orphan.pid"
kill -0 "$orphan_pid" 2>/dev/null || fail "orphan did not survive its parent"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- true 2>&1)" || rc=$?
[[ "$rc" == 75 ]] ||
  fail "slot must stay held while the orphan lives (rc=$rc): $out"
kill "$orphan_pid" 2>/dev/null || true
heavy_dead "$orphan_pid" || fail "orphan sleep did not die"
WRK_HEAVY_WAIT_CAP=5 "$WRK" heavy -- true ||
  fail "slot not reclaimed after the whole holder tree died"
echo "PASS heavy-orphan-slot-dies-with-tree"

# load gate: load5/ncpu >= 1.0 blocks the start and is bounded by the same cap.
# The boundary is exact: a ratio of precisely 1.0 still blocks (the gate is
# "wait while >= 1.0", not ">").
printf '9.9\n' >"$HEAVY_LOAD"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- bash "$TMP/touch-load.sh" 2>&1)" || rc=$?
[[ "$rc" == 75 ]] || fail "load gate must exit 75 at the cap, got rc=$rc"
grep -q 'load5/ncpu' <<<"$out" || fail "load-gate expiry must say why: $out"
[[ ! -e "$TMP/heavy-load-ran" ]] || fail "command ran despite the load gate"
printf '1.0\n' >"$HEAVY_LOAD"
rc=0
out="$(WRK_HEAVY_WAIT_CAP=3 "$WRK" heavy -- bash "$TMP/touch-load3.sh" 2>&1)" || rc=$?
[[ "$rc" == 75 ]] || fail "load ratio 1.0 must still block, got rc=$rc"
[[ ! -e "$TMP/heavy-load-ran3" ]] || fail "command ran at the 1.0 boundary"
printf '9.9\n' >"$HEAVY_LOAD"
"$WRK" heavy -- bash "$TMP/touch-load2.sh" &
waiter_job=$!
sleep 2
printf '0\n' >"$HEAVY_LOAD"
wait "$waiter_job" || fail "run did not start after the load gate opened"
[[ -e "$TMP/heavy-load-ran2" ]] || fail "load-gated run never executed"
echo "PASS heavy-load-gate-bounds-the-start"

echo 'PASS test-wrk'
