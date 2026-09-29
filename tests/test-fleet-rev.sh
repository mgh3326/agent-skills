#!/usr/bin/env bash
# Task 957 — fleet-rev acceptance tests. Fully hermetic: a fake ssh runs the
# probe under per-host fixture HOMEs, a fake gh answers commits/main and
# compare from fixture files, and HOME for the local probe is a fixture dir.
# FLEET_REV_BIN overrides the binary under test (used for mutant runs).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET_REV="${FLEET_REV_BIN:-$ROOT/bin/fleet-rev}"
FIX="$ROOT/tests/fixtures/fleet-rev"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

export WRK_HOSTS_CONFIG="$TMP/hosts.toml"
export FLEET_REV_SSH="$FIX/fake-ssh"
export FLEET_REV_GH="$FIX/fake-gh"
export FLEET_REV_SSH_LOG="$TMP/ssh.log"
export FLEET_REV_GH_LOG="$TMP/gh.log"
FAKE_ROOT="$TMP/homes"
GHDIR="$TMP/gh"
LOCAL_HOME="$TMP/local-home"
export FLEET_REV_FAKE_ROOT="$FAKE_ROOT"
export FLEET_REV_FAKE_GH_DIR="$GHDIR"

cat >"$WRK_HOSTS_CONFIG" <<'EOF'
[hosts.a]
ssh = "x"
[hosts.b]
#[hosts.c]
#ssh = "c-alias"
EOF

# ---------------------------------------------------------------- helpers

sha40() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-40
  else
    printf '%s' "$1" | sha256sum | cut -c1-40
  fi
}
sha_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}
mtime_of() { python3 -c "import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)" "$1"; }
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'; }
remote_home() { printf '%s/%s' "$FAKE_ROOT" "$(sanitize "$1")"; }

reset_env() {
  rm -rf "$FAKE_ROOT" "$GHDIR" "$LOCAL_HOME"
  mkdir -p "$FAKE_ROOT" "$GHDIR" "$LOCAL_HOME"
  : >"$FLEET_REV_SSH_LOG"; : >"$FLEET_REV_GH_LOG"
  unset FLEET_REV_FAKE_DEAD FLEET_REV_FAKE_SLEEP FLEET_REV_FAKE_SLEEP_S 2>/dev/null || true
}

mk_home() { mkdir -p "$1/.local/bin" "$1/.fleet-rev"; }

give_scopefuel() { # home rev|missing|norev [dep-rev]
  local dir="$1/.local/share/uv/tools/scopefuel"
  case "$2" in
    missing) rm -f "$dir/uv-receipt.toml" ;;
    norev)
      mkdir -p "$dir"
      printf '[tool]\nrequirements = []\n' >"$dir/uv-receipt.toml" ;;
    *)
      mkdir -p "$dir"
      if [[ -n "${3:-}" ]]; then
        printf '[tool]\nrequirements = [{ name = "scopefuel", git = "https://github.com/mgh3326/scopefuel?rev=%s" }, { name = "dep", git = "https://github.com/mgh3326/scopefuel?rev=%s" }]\n' \
          "$2" "$3" >"$dir/uv-receipt.toml"
      else
        printf '[tool]\nrequirements = [{ name = "scopefuel", git = "https://github.com/mgh3326/scopefuel?rev=%s" }]\n' \
          "$2" >"$dir/uv-receipt.toml"
      fi ;;
  esac
}

CANON_AS="$TMP/as-canon"
mk_canon_agentskills() {
  mkdir -p "$CANON_AS"
  git -C "$CANON_AS" init -q
  git -C "$CANON_AS" -c user.email=t@t -c user.name=t commit -qm c1 --allow-empty
  git -C "$CANON_AS" -c user.email=t@t -c user.name=t commit -qm c2 --allow-empty
}

give_agentskills() { # home -> re-clones canon so the checkout is clean; echoes HEAD
  mkdir -p "$1/.agents"
  rm -rf "$1/.agents/skills"
  git clone -q "$CANON_AS" "$1/.agents/skills"
  git -C "$1/.agents/skills" rev-parse HEAD
}

dirty_agentskills() { printf 'x\n' >"$1/.agents/skills/UNTRACKED"; }

give_panewire() { # home rev (printed as pw-<rev>)
  cp "$FIX/panewire" "$1/.local/bin/panewire"
  printf '%s' "$2" >"$1/.fleet-rev/panewire-rev"
}

give_handoffkeep() { # home mode[json|old|old-nogo] rev modified?
  cp "$FIX/handoffkeep" "$1/.local/bin/handoffkeep"
  rm -f "$1/.local/bin/go" "$1/.fleet-rev/go-rev" "$1/.fleet-rev/go-modified"
  printf '%s' "$2" >"$1/.fleet-rev/hk-mode"
  printf '%s' "$3" >"$1/.fleet-rev/hk-rev"
  printf '%s' "${4:-false}" >"$1/.fleet-rev/hk-modified"
  if [[ "$2" == "old" ]]; then
    cp "$FIX/go" "$1/.local/bin/go"
    printf '%s' "$3" >"$1/.fleet-rev/go-rev"
    printf '%s' "${4:-false}" >"$1/.fleet-rev/go-modified"
  fi
}

set_main() { printf '%s\n' "$2" >"$GHDIR/$1.main"; }
set_compare() { printf '%s %s %s\n' "$2" "$3" "$4" >>"$GHDIR/$1.compare"; }

run_fleet() {
  set +e
  OUT="$(HOME="$LOCAL_HOME" "$FLEET_REV" "$@" 2>"$TMP/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP/err")"
}

cell() { # host tool -> status column onwards from the table
  awk -v h="$1" -v t="$2" '$1==h&&$2==t{ $1=$2=$3=$4=""; sub(/^ +/,""); print }' <<<"$OUT"
}

assert_cell() { # host tool expected-prefix
  local got; got="$(cell "$1" "$2")"
  [[ "$got" == "$3"* ]] || fail "cell $1/$2: want '$3...', got '$got'"
}

jval() { printf '%s' "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }

ssh_aliases() { awk '{for(i=1;i<NF;i++) if($i=="sh"&&$(i+1)=="-s") print $(i-1)}' "$FLEET_REV_SSH_LOG"; }

mk_canon_agentskills

# ================================================================ AC1
# All four tools current on two hosts -> all cells current, rc 0.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"

full_current_home() {
  mk_home "$1"
  give_scopefuel "$1" "$S_MAIN"
  give_agentskills "$1" >/dev/null
  give_panewire "$1" "$PW7"
  give_handoffkeep "$1" json "$HK_MAIN" false
}
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"

run_fleet --only local,a
[[ $RC -eq 0 ]] || fail "AC1 rc: want 0 got $RC :: $OUT $ERR"
for h in local a; do
  for t in scopefuel agent-skills panewire handoffkeep; do assert_cell "$h" "$t" "current"; done
done
[[ "$(tail -n1 <<<"$OUT")" == "fleet-rev: rc=0 current=8 behind=0 diverged=0 other=0" ]] ||
  fail "AC1 summary: $(tail -n1 <<<"$OUT")"
pass "AC1 all-current fleet: 8/8 cells current, rc 0, summary counts"

# ================================================================ AC2
# One tool behind on one host -> that cell 'behind 3', rc 1. Same shape on the
# first host (local) keeps the aggregate honest (a last-host-only rc would
# pass a remote failure silently). Compare 404 -> diverged, rc 1.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"

S_OLD="$(sha40 s-old)"
give_scopefuel "$(remote_home x)" "$S_OLD"
set_compare scopefuel "$S_OLD" ahead 3
run_fleet --only local,a
[[ $RC -eq 1 ]] || fail "AC2 remote-behind rc: want 1 got $RC :: $OUT"
assert_cell a scopefuel "behind 3"
assert_cell local scopefuel "current"
[[ "$(tail -n1 <<<"$OUT")" == "fleet-rev: rc=1 current=7 behind=1 diverged=0 other=0" ]] ||
  fail "AC2 summary: $(tail -n1 <<<"$OUT")"

# same staleness on the FIRST host: rc must still be 1 (aggregate, not last-host)
full_current_home "$(remote_home x)"
give_scopefuel "$LOCAL_HOME" "$S_OLD"
run_fleet --only local,a
[[ $RC -eq 1 ]] || fail "AC2 local-behind rc: want 1 got $RC :: $OUT"
assert_cell local scopefuel "behind 3"
assert_cell a scopefuel "current"

# compare answering 404 (installed unknown to GitHub) -> diverged
rm -f "$GHDIR/scopefuel.compare"
run_fleet --only local,a
[[ $RC -eq 1 ]] || fail "AC2 diverged rc: want 1 got $RC :: $OUT"
assert_cell local scopefuel "diverged"

# a transient compare failure (HTTP 502) is NOT diverged: status unknown,
# detail 'compare failed', rc 3 — only a real 404 means diverged
set_compare scopefuel "$S_OLD" http 502
run_fleet --only local --json
[[ $RC -eq 3 ]] || fail "AC2 compare-502 rc: want 3 got $RC :: $OUT"
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["status"]')" == "unknown" ]] ||
  fail "AC2 compare-502 status: $(jval '["hosts"][0]["tools"]["scopefuel"]')"
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["detail"]')" == *"compare failed"* ]] ||
  fail "AC2 compare-502 detail: $(jval '["hosts"][0]["tools"]["scopefuel"]["detail"]')"
pass "AC2 behind (either host order), compare-404 diverged and compare-502 unknown"

# ================================================================ AC3
# Unreachable host: all four cells unreachable, others still probed. rc 3 when
# nothing is behind; rc 1 as soon as any reachable cell is behind.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"
mk_home "$(remote_home b)"

export FLEET_REV_FAKE_DEAD="b"
run_fleet --only local,a,b
[[ $RC -eq 3 ]] || fail "AC3 dead rc: want 3 got $RC :: $OUT"
for t in scopefuel agent-skills panewire handoffkeep; do
  assert_cell b "$t" "unreachable"
done
assert_cell local scopefuel "current"; assert_cell a panewire "current"
[[ "$(tail -n1 <<<"$OUT")" == "fleet-rev: rc=3 current=8 behind=0 diverged=0 other=4" ]] ||
  fail "AC3 dead summary: $(tail -n1 <<<"$OUT")"

# a behind cell plus an unreachable host is still rc 1
S_OLD="$(sha40 s-old2)"
give_scopefuel "$LOCAL_HOME" "$S_OLD"
set_compare scopefuel "$S_OLD" ahead 5
run_fleet --only local,a,b
[[ $RC -eq 1 ]] || fail "AC3 dead+behind rc: want 1 got $RC :: $OUT"
assert_cell local scopefuel "behind 5"
assert_cell b scopefuel "unreachable"
unset FLEET_REV_FAKE_DEAD

# a host whose ssh stalls past --timeout is unreachable too
full_current_home "$LOCAL_HOME"
export FLEET_REV_FAKE_SLEEP="b" FLEET_REV_FAKE_SLEEP_S=8
run_fleet --only local,a,b --timeout 5
[[ $RC -eq 3 ]] || fail "AC3 slow rc: want 3 got $RC :: $OUT"
assert_cell b scopefuel "unreachable timeout"
assert_cell a scopefuel "current"
unset FLEET_REV_FAKE_SLEEP FLEET_REV_FAKE_SLEEP_S
pass "AC3 ssh-fail and ssh-timeout hosts read unreachable on all four tools"

# ================================================================ AC4
# handoffkeep sources: version --json -> version-cmd; older binary + go
# version -m -> go-buildinfo; neither -> unknown/none. modified=true shows as
# current with a modified detail; a dirty agent-skills checkout at main too.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
mk_home "$LOCAL_HOME"
give_scopefuel "$LOCAL_HOME" "$S_MAIN"
give_agentskills "$LOCAL_HOME" >/dev/null
give_panewire "$LOCAL_HOME" "$PW7"

give_handoffkeep "$LOCAL_HOME" json "$HK_MAIN" false
run_fleet --only local --json
[[ $RC -eq 0 ]] || fail "AC4 json rc: want 0 got $RC :: $OUT"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["source"]')" == "version-cmd" ]] ||
  fail "AC4 json source: $(jval '["hosts"][0]["tools"]["handoffkeep"]')"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["installed"]')" == "$HK_MAIN" ]] ||
  fail "AC4 json installed mismatch"

# version --json with modified:"true" (real #958 shape: every field is a
# string) -> current+modified with source version-cmd
give_handoffkeep "$LOCAL_HOME" json "$HK_MAIN" true
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["status"]')" == "current" ]] ||
  fail "AC4 version-cmd modified status: $(jval '["hosts"][0]["tools"]["handoffkeep"]')"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')" == *modified* ]] ||
  fail "AC4 version-cmd modified detail: $(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["source"]')" == "version-cmd" ]] ||
  fail "AC4 version-cmd modified source"
run_fleet --only local
assert_cell local handoffkeep "current+modified"

give_handoffkeep "$LOCAL_HOME" old "$HK_MAIN" false
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["source"]')" == "go-buildinfo" ]] ||
  fail "AC4 buildinfo source: $(jval '["hosts"][0]["tools"]["handoffkeep"]')"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["status"]')" == "current" ]] ||
  fail "AC4 buildinfo status: $(jval '["hosts"][0]["tools"]["handoffkeep"]')"

give_handoffkeep "$LOCAL_HOME" old "$HK_MAIN" true
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["status"]')" == "current" ]] ||
  fail "AC4 modified status"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')" == *modified* ]] ||
  fail "AC4 modified detail: $(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')"
run_fleet --only local
assert_cell local handoffkeep "current+modified"

give_handoffkeep "$LOCAL_HOME" old-nogo "$HK_MAIN" false
run_fleet --only local --json
[[ $RC -eq 3 ]] || fail "AC4 no-source rc: want 3 got $RC"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["status"]')" == "unknown" ]] ||
  fail "AC4 no-source status: $(jval '["hosts"][0]["tools"]["handoffkeep"]')"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["source"]')" == "none" ]] ||
  fail "AC4 no-source source"

# a version --json answer that is not the contracted object -> bad version json
give_handoffkeep "$LOCAL_HOME" badjson "$HK_MAIN" false
run_fleet --only local --json
[[ $RC -eq 3 ]] || fail "AC4 badjson rc: want 3 got $RC"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["status"]')" == "unknown" ]] ||
  fail "AC4 badjson status: $(jval '["hosts"][0]["tools"]["handoffkeep"]')"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')" == *"bad version json"* ]] ||
  fail "AC4 badjson detail: $(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')"

# agent-skills at main with an uncommitted file -> current + modified detail
dirty_agentskills "$LOCAL_HOME"
give_handoffkeep "$LOCAL_HOME" json "$HK_MAIN" false
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["agent-skills"]["status"]')" == "current" ]] ||
  fail "AC4 dirty status"
[[ "$(jval '["hosts"][0]["tools"]["agent-skills"]["detail"]')" == *"modified (dirty=1)"* ]] ||
  fail "AC4 dirty detail: $(jval '["hosts"][0]["tools"]["agent-skills"]["detail"]')"
run_fleet --only local
assert_cell local agent-skills "current+modified"
pass "AC4 handoffkeep version-cmd/go-buildinfo/none + modified and dirty details"

# ================================================================ AC5
# panewire pw-<7hex>: a prefix of main is current without a compare call; a
# 7-hex value that is merely a substring of main is NOT current (goes to
# compare). Invariant: only a prefix counts.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
mk_home "$LOCAL_HOME"
give_scopefuel "$LOCAL_HOME" "$S_MAIN"
give_agentskills "$LOCAL_HOME" >/dev/null
give_panewire "$LOCAL_HOME" "$PW7"
give_handoffkeep "$LOCAL_HOME" json "$HK_MAIN" false

run_fleet --only local
assert_cell local panewire "current"
grep -q 'panewire/compare' "$FLEET_REV_GH_LOG" &&
  fail "AC5 prefix case made a compare call: $(cat "$FLEET_REV_GH_LOG")"

# substring (not prefix) of main -> goes to compare -> behind
PW_MAIN2="aa${PW7}$(sha40 pw-mid | cut -c10-40)"
set_main panewire "$PW_MAIN2"
set_compare panewire "$PW7" ahead 4
run_fleet --only local
assert_cell local panewire "behind 4"

# not a prefix at all and unknown to GitHub -> diverged
give_panewire "$LOCAL_HOME" "0000000"
run_fleet --only local
assert_cell local panewire "diverged"
pass "AC5 pw-7hex counts as current only as a prefix of main"

# ================================================================ AC6
# scopefuel receipt: rev= -> that rev; missing receipt -> absent; receipt
# without rev= -> unknown.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"
full_current_home "$(remote_home b)"
give_scopefuel "$(remote_home x)" missing
give_scopefuel "$(remote_home b)" norev

run_fleet --only local,a,b --json
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["installed"]')" == "$S_MAIN" ]] ||
  fail "AC6 rev= installed"
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["status"]')" == "current" ]] ||
  fail "AC6 rev= status"
[[ "$(jval '["hosts"][1]["tools"]["scopefuel"]["status"]')" == "absent" ]] ||
  fail "AC6 missing status: $(jval '["hosts"][1]["tools"]["scopefuel"]')"
[[ "$(jval '["hosts"][1]["tools"]["scopefuel"]["installed"]')" == "None" ]] ||
  fail "AC6 missing installed"
[[ "$(jval '["hosts"][2]["tools"]["scopefuel"]["status"]')" == "unknown" ]] ||
  fail "AC6 norev status: $(jval '["hosts"][2]["tools"]["scopefuel"]')"
[[ $RC -eq 3 ]] || fail "AC6 rc: want 3 got $RC"

# a rev that is not >=7 lowercase hex is 'bad rev' (unknown), never a prefix
# match: a 1-char rev must not ride the prefix rule into 'current'
set_main scopefuel "a$(sha40 s-a | cut -c2-40)"
give_scopefuel "$LOCAL_HOME" "a"
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["status"]')" == "unknown" ]] ||
  fail "AC6 1-char status: $(jval '["hosts"][0]["tools"]["scopefuel"]')"
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["detail"]')" == *"bad rev"* ]] ||
  fail "AC6 1-char detail: $(jval '["hosts"][0]["tools"]["scopefuel"]["detail"]')"

give_scopefuel "$LOCAL_HOME" "zzzzzzzz"
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["status"]')" == "unknown" ]] ||
  fail "AC6 non-hex status: $(jval '["hosts"][0]["tools"]["scopefuel"]')"
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["detail"]')" == *"bad rev"* ]] ||
  fail "AC6 non-hex detail: $(jval '["hosts"][0]["tools"]["scopefuel"]["detail"]')"

# a --with dep on the same requirements line (even on the scopefuel repo at a
# different rev) is never picked: the rev must come from scopefuel's own entry
DEP_REV="$(sha40 dep-rev)"
set_main scopefuel "$S_MAIN"
give_scopefuel "$LOCAL_HOME" "$S_MAIN" "$DEP_REV"
set_compare scopefuel "$S_MAIN" identical 0
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["installed"]')" == "$S_MAIN" ]] ||
  fail "AC6 dep-shadow installed: $(jval '["hosts"][0]["tools"]["scopefuel"]')"
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["status"]')" == "current" ]] ||
  fail "AC6 dep-shadow status: $(jval '["hosts"][0]["tools"]["scopefuel"]')"
pass "AC6 receipt rev=/missing/no-rev -> installed/absent/unknown; bad rev and dep rev rejected"

# ================================================================ AC7
# hosts.toml: [hosts.a] ssh="x" (alias x), [hosts.b] (alias b), commented
# [hosts.c] never a host. --extra adds, --skip drops, --only selects.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"
full_current_home "$(remote_home b)"
full_current_home "$(remote_home m1)"

run_fleet
[[ $RC -eq 0 ]] || fail "AC7 default rc: want 0 got $RC :: $OUT"
[[ "$(ssh_aliases | sort -u | tr '\n' ' ')" == "b x " ]] ||
  fail "AC7 default aliases: $(ssh_aliases | sort -u | tr '\n' ' ')"
grep -q '^c ' <<<"$OUT" && fail "AC7 commented host c was probed"
grep -q 'c-alias' "$FLEET_REV_SSH_LOG" && fail "AC7 c-alias was probed"
grep -q '^a ' <<<"$OUT" || fail "AC7 host a row missing"
grep -q '^b ' <<<"$OUT" || fail "AC7 host b row missing"

: >"$FLEET_REV_SSH_LOG"
run_fleet --extra m=m1
[[ "$(ssh_aliases | sort -u | tr '\n' ' ')" == "b m1 x " ]] ||
  fail "AC7 extra aliases: $(ssh_aliases | sort -u | tr '\n' ' ')"
grep -q '^m ' <<<"$OUT" || fail "AC7 host m row missing"

: >"$FLEET_REV_SSH_LOG"
run_fleet --skip a
[[ "$(ssh_aliases | sort -u | tr '\n' ' ')" == "b " ]] ||
  fail "AC7 skip aliases: $(ssh_aliases | sort -u | tr '\n' ' ')"
grep -q '^a ' <<<"$OUT" && fail "AC7 skipped host a still in table"

: >"$FLEET_REV_SSH_LOG"
run_fleet --only b
[[ "$(ssh_aliases)" == "b" ]] || fail "AC7 only aliases: $(ssh_aliases)"
grep -q '^local ' <<<"$OUT" && fail "AC7 --only b still probed local"
grep -q '^b ' <<<"$OUT" || fail "AC7 --only b row missing"

# wrk spillover shapes: the FIRST ssh= in a section wins, and a [hosts.NAME]
# header with a trailing comment is still a header
cat >"$WRK_HOSTS_CONFIG" <<'EOF'
[hosts.a]
ssh = "x"
ssh = "x2"
[hosts.q] # desktop
ssh = "qq"
EOF
full_current_home "$(remote_home qq)"
: >"$FLEET_REV_SSH_LOG"
run_fleet
[[ "$(ssh_aliases | sort -u | tr '\n' ' ')" == "qq x " ]] ||
  fail "AC7 dup-ssh/comment-header aliases: $(ssh_aliases | sort -u | tr '\n' ' ')"
grep -q 'x2' "$FLEET_REV_SSH_LOG" && fail "AC7 last ssh= won: $(cat "$FLEET_REV_SSH_LOG")"
grep -q '^a ' <<<"$OUT" || fail "AC7 host a row missing"
grep -q '^q ' <<<"$OUT" || fail "AC7 trailing-comment header q is not a host"
cat >"$WRK_HOSTS_CONFIG" <<'EOF'
[hosts.a]
ssh = "x"
[hosts.b]
#[hosts.c]
#ssh = "c-alias"
EOF
pass "AC7 hosts.toml parse + --extra/--skip/--only + first-ssh/trailing-comment"

# ================================================================ AC8
# --json: exactly the contracted keys, and its rc equals the process rc.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"
S_OLD="$(sha40 s-old)"
give_scopefuel "$(remote_home x)" "$S_OLD"
set_compare scopefuel "$S_OLD" ahead 2

run_fleet --only local,a --json
[[ $RC -eq 1 ]] || fail "AC8 rc: want 1 got $RC"
cat >"$TMP/jsoncheck.py" <<'PY'
import json, sys
d = json.load(sys.stdin)
assert set(d) == {"main", "hosts", "rc"}, set(d)
assert set(d["main"]) == {"scopefuel", "agent-skills", "panewire", "handoffkeep"}, set(d["main"])
for h in d["hosts"]:
    assert set(h) == {"host", "alias", "reachable", "tools"}, set(h)
    assert set(h["tools"]) == {"scopefuel", "agent-skills", "panewire", "handoffkeep"}
    for t in h["tools"].values():
        assert set(t) == {"installed", "status", "behind", "source", "detail"}, set(t)
assert d["rc"] == int(sys.argv[1]), (d["rc"], sys.argv[1])
assert d["hosts"][0]["host"] == "local" and d["hosts"][0]["reachable"] is True
assert d["hosts"][1]["tools"]["scopefuel"]["status"] == "behind"
assert d["hosts"][1]["tools"]["scopefuel"]["behind"] == 2
PY
printf '%s' "$OUT" | python3 "$TMP/jsoncheck.py" "$RC" || fail "AC8 json contract"
pass "AC8 --json exact keys; rc field equals process exit code"

# ================================================================ AC9
# Safety: every ssh call is BatchMode+ConnectTimeout+sh -s; the probe reads no
# env/token/config besides the receipt and git; no write/install command.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"
run_fleet --only local,a
[[ -s "$FLEET_REV_SSH_LOG" ]] || fail "AC9 ssh never called"
bad="$(grep -vE '^-o BatchMode=yes -o ConnectTimeout=10 -- [^ ]+ sh -s$' "$FLEET_REV_SSH_LOG" || true)"
[[ -z "$bad" ]] || fail "AC9 unsafe ssh argv: $bad"

# an alias starting with '-' must not become an ssh option: -- guards it
: >"$FLEET_REV_SSH_LOG"
run_fleet --extra 'z=-oProxyCommand=echo' --only z || true
[[ "$(cat "$FLEET_REV_SSH_LOG")" == '-o BatchMode=yes -o ConnectTimeout=10 -- -oProxyCommand=echo sh -s' ]] ||
  fail "AC9 dash-alias argv: $(cat "$FLEET_REV_SSH_LOG")"

python3 - "$ROOT/bin/fleet-rev" >"$TMP/probe.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
print(re.search(r'PROBE = r"""(.*?)"""', src, re.S).group(1))
PY
bad="$(grep -nE '(^|[ ;&|])(systemctl|launchctl|scp|rsync|tee|sed -i|cp|mv|rm|mkdir|chmod|ln|brew|apt|pip)([ ;&|]|$)|(^|[ ;&|])install([ ;&|]|$)|uv tool|git (config|remote|pull|push|fetch|checkout|clean|reset|commit|clone)' "$TMP/probe.sh" || true)"
[[ -z "$bad" ]] || fail "AC9 probe write/install command: $bad"
bad="$(grep -oE '>[0-9A-Za-z&/_.-]*' "$TMP/probe.sh" | grep -vE '^>(/dev/null|&[12])$' || true)"
[[ -z "$bad" ]] || fail "AC9 probe redirect: $bad"
bad="$(grep -inE 'token|secret|\.env|id_rsa|netrc|\.aws|password|credential' "$TMP/probe.sh" || true)"
[[ -z "$bad" ]] || fail "AC9 probe secret read: $bad"
envnames="$(grep -oE 'environ\.get\("[A-Z_]+"|environ\["[A-Z_]+"\]' "$ROOT/bin/fleet-rev" | grep -oE '"[A-Z_]+"' | tr -d '"' | sort -u | tr '\n' ' ')"
[[ "$envnames" == "FLEET_REV_GH FLEET_REV_SSH WRK_HOSTS_CONFIG XDG_CONFIG_HOME " ]] ||
  fail "AC9 env reads: $envnames"

# B1: the probe must not write .git/index — git's opportunistic index refresh
# is off (GIT_OPTIONAL_LOCKS=0), so a stale-stat checkout stays byte-identical
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$(remote_home x)"
IDX_HOME="$(remote_home x)"
printf 'seed\n' >"$IDX_HOME/.agents/skills/tracked.txt"
git -C "$IDX_HOME/.agents/skills" add tracked.txt
sleep 1
touch "$IDX_HOME/.agents/skills/tracked.txt"
IDX="$IDX_HOME/.agents/skills/.git/index"
IDX_BEFORE="$(sha_file "$IDX")|$(mtime_of "$IDX")"
run_fleet --only a
IDX_AFTER="$(sha_file "$IDX")|$(mtime_of "$IDX")"
[[ "$IDX_BEFORE" == "$IDX_AFTER" ]] ||
  fail "AC9 probe rewrote .git/index: $IDX_BEFORE -> $IDX_AFTER"
pass "AC9 probe is read-only: argv safe, no writes, no secret/env reads, git index untouched"

# ================================================================ AC10 (993 N3)
# A receipt keeps rev= as typed, so an uppercase-hex rev must compare as its
# lowercase form: prefix-of-main -> current, otherwise compare -> behind.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"

S_UPPER="$(printf '%s' "$S_MAIN" | tr 'a-f' 'A-F')"
[[ "$S_UPPER" != "$S_MAIN" ]] || fail "AC10 fixture: S_MAIN has no a-f letters"
give_scopefuel "$LOCAL_HOME" "$S_UPPER"
run_fleet --only local --json
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["installed"]')" == "$S_MAIN" ]] ||
  fail "AC10 uppercase installed: $(jval '["hosts"][0]["tools"]["scopefuel"]')"
[[ "$(jval '["hosts"][0]["tools"]["scopefuel"]["status"]')" == "current" ]] ||
  fail "AC10 uppercase status: $(jval '["hosts"][0]["tools"]["scopefuel"]')"

S_OLD="$(sha40 s-old)"
give_scopefuel "$LOCAL_HOME" "$(printf '%s' "$S_OLD" | tr 'a-f' 'A-F')"
set_compare scopefuel "$S_OLD" ahead 4
run_fleet --only local
[[ $RC -eq 1 ]] || fail "AC10 uppercase-behind rc: want 1 got $RC :: $OUT"
assert_cell local scopefuel "behind 4"
pass "AC10 uppercase receipt rev lowercased before validating (N3)"

# ================================================================ AC11 (993 N4)
# The summary counts behind and diverged separately (they used to share
# behind=). --json shape is unchanged (the AC8 key contract still holds).
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"
S_OLD="$(sha40 s-old)"; S_OTHER="$(sha40 s-other)"
give_scopefuel "$LOCAL_HOME" "$S_OLD"
set_compare scopefuel "$S_OLD" ahead 3
# a's rev has no compare entry -> gh 404 -> diverged (not behind)
give_scopefuel "$(remote_home x)" "$S_OTHER"
run_fleet --only local,a
[[ $RC -eq 1 ]] || fail "AC11 rc: want 1 got $RC :: $OUT"
assert_cell local scopefuel "behind 3"
assert_cell a scopefuel "diverged"
[[ "$(tail -n1 <<<"$OUT")" == "fleet-rev: rc=1 current=6 behind=1 diverged=1 other=0" ]] ||
  fail "AC11 summary: $(tail -n1 <<<"$OUT")"
run_fleet --only local,a --json
[[ "$(jval '["hosts"][1]["tools"]["scopefuel"]["status"]')" == "diverged" ]] ||
  fail "AC11 json diverged: $(jval '["hosts"][1]["tools"]["scopefuel"]')"
pass "AC11 summary splits behind= and diverged= (N4)"

# ================================================================ AC12 (993 N5)
# handoffkeep version --json answering rev "unknown" is a parseable answer
# that names the problem, not an empty detail.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
give_handoffkeep "$LOCAL_HOME" json unknown false
run_fleet --only local --json
[[ $RC -eq 3 ]] || fail "AC12 rc: want 3 got $RC :: $OUT"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["status"]')" == "unknown" ]] ||
  fail "AC12 status: $(jval '["hosts"][0]["tools"]["handoffkeep"]')"
[[ "$(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')" == *"version json rev unknown"* ]] ||
  fail "AC12 detail: $(jval '["hosts"][0]["tools"]["handoffkeep"]["detail"]')"
pass "AC12 handoffkeep rev 'unknown' says 'version json rev unknown' (N5)"

# ================================================================ AC13 (993 N6)
# A hung version tool is bounded inside the probe: that cell reads unknown /
# 'tool timed out', the host stays reachable and its other tools still
# report. Invariant: a hung tool never makes its host unreachable. The run's
# own outer bound is --timeout 15 plus the elapsed assertion.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"

printf '63\n' >"$(remote_home x)/.fleet-rev/panewire-hang"
SECONDS=0
run_fleet --only a --timeout 15
ELA=$SECONDS
[[ $RC -eq 3 ]] || fail "AC13 hung-panewire rc: want 3 got $RC :: $OUT"
assert_cell a panewire "unknown"
[[ "$(cell a panewire)" == *"tool timed out"* ]] ||
  fail "AC13 panewire detail: $(cell a panewire)"
for t in scopefuel agent-skills handoffkeep; do
  assert_cell a "$t" "current" || fail "AC13 $t did not report"
done
[[ $ELA -lt 10 ]] ||
  fail "AC13 hung tool stalled the run: ${ELA}s (bound 3s + kill grace 1s)"
# no process left behind: the exec'd 'sleep 63' must be gone from the table
if pgrep -f 'sleep 63' >/dev/null 2>&1; then
  fail "AC13 left a hung panewire process behind: $(pgrep -fl 'sleep 63')"
fi
pass "AC13 hung panewire -> unknown 'tool timed out', host stays reachable (N6)"

rm -f "$(remote_home x)/.fleet-rev/panewire-hang"
printf '63\n' >"$(remote_home x)/.fleet-rev/hk-hang"
SECONDS=0
run_fleet --only a --timeout 15
ELA=$SECONDS
[[ $RC -eq 3 ]] || fail "AC13 hung-handoffkeep rc: want 3 got $RC :: $OUT"
assert_cell a handoffkeep "unknown"
[[ "$(cell a handoffkeep)" == *"tool timed out"* ]] ||
  fail "AC13 handoffkeep detail: $(cell a handoffkeep)"
for t in scopefuel agent-skills panewire; do
  assert_cell a "$t" "current" || fail "AC13 $t did not report"
done
[[ $ELA -lt 10 ]] ||
  fail "AC13 hung handoffkeep stalled the run: ${ELA}s"
if pgrep -f 'sleep 63' >/dev/null 2>&1; then
  fail "AC13 left a hung handoffkeep process behind: $(pgrep -fl 'sleep 63')"
fi
pass "AC13 hung handoffkeep -> unknown 'tool timed out', host stays reachable (N6)"

# ================================================================ AC14 (993 CodeRabbit)
# An explicitly set WRK_HOSTS_CONFIG that is missing or unreadable is a
# usage error (rc 2, one stderr line) — not a silent local-only run. The
# default path missing only warns once and probes local. Invariant: an
# explicit missing config is an error.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
full_current_home "$LOCAL_HOME"
full_current_home "$(remote_home x)"

export WRK_HOSTS_CONFIG="$TMP/no-such.toml"
run_fleet --only local
[[ $RC -eq 2 ]] || fail "AC14 missing explicit config rc: want 2 got $RC :: $OUT"
[[ "$(printf '%s\n' "$ERR" | grep -c .)" -eq 1 ]] ||
  fail "AC14 stderr line count: $(printf '%s\n' "$ERR" | grep -c .) :: $ERR"
[[ "$ERR" == *WRK_HOSTS_CONFIG* ]] ||
  fail "AC14 stderr does not name WRK_HOSTS_CONFIG: $ERR"

# an unreadable explicit config errors the same way
printf '[hosts.a]\nssh = "x"\n' >"$TMP/no-read.toml"
chmod 000 "$TMP/no-read.toml"
export WRK_HOSTS_CONFIG="$TMP/no-read.toml"
run_fleet --only local
[[ $RC -eq 2 ]] || fail "AC14 unreadable explicit config rc: want 2 got $RC :: $OUT"
chmod 644 "$TMP/no-read.toml"
export WRK_HOSTS_CONFIG="$TMP/hosts.toml"

# unset -> default path missing -> one warning, local probed, rc as usual
set +e
OUT="$(HOME="$LOCAL_HOME" env -u WRK_HOSTS_CONFIG -u XDG_CONFIG_HOME \
  "$FLEET_REV" --only local 2>"$TMP/err")"
RC=$?
set -e
ERR="$(cat "$TMP/err")"
[[ $RC -eq 0 ]] || fail "AC14 default-missing rc: want 0 got $RC :: $OUT"
[[ "$(printf '%s\n' "$ERR" | grep -c .)" -eq 1 && "$ERR" == *warning* ]] ||
  fail "AC14 default-missing warning: $ERR"
[[ "$(awk '$2=="scopefuel"{print $1}' <<<"$OUT" | sort -u)" == "local" ]] ||
  fail "AC14 default-missing probed more than local: $OUT"
pass "AC14 explicit missing/unreadable config rc 2; default missing warns once (CodeRabbit)"

# ================================================================ AC15 (993 N7)
# The README scopefuel reinstall step labels the `git+...@<sha> --force`
# form as fleet-rev's own recommended form (it is not cited from the
# scopefuel README, which shows only a rev-less `uv tool install git+...`).
line="$(grep -A2 'uv tool install --force' "$ROOT/README.md")"
[[ "$line" == *scopefuel* && "$line" == *권장* ]] ||
  fail "AC15 README scopefuel form not labelled recommended: $line"
pass "AC15 README labels the scopefuel @<sha> form as recommended (N7)"

# ================================================================ AC16 (1007 B1)
# A tool that is a non-exec sh wrapper — the real work runs as a CHILD, so
# killing only the wrapper leaves a grandchild holding the output pipe.
# Invariant I-M1: a wrapper's grandchild never outlives the bound. Both
# shapes (foreground child, 'sleep & wait') must read unknown with
# 'tool timed out', the host stays reachable, the run ends inside the
# bound plus margin (its own outer bound is --timeout 30), and no
# grandchild survives.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"

full_current_home "$(remote_home x)"
# wrapper shape 1: the real tool is a foreground child of the wrapper
cat >"$(remote_home x)/.local/bin/panewire" <<'EOF'
#!/bin/sh
sleep 61
printf 'pw-deadbee\n'
EOF
chmod +x "$(remote_home x)/.local/bin/panewire"
SECONDS=0
run_fleet --only a --timeout 30
ELA=$SECONDS
[[ $RC -eq 3 ]] || fail "AC16 child-form rc: want 3 got $RC :: $OUT"
assert_cell a panewire "unknown"
[[ "$(cell a panewire)" == *"tool timed out"* ]] ||
  fail "AC16 child-form detail: $(cell a panewire)"
for t in scopefuel agent-skills handoffkeep; do
  assert_cell a "$t" "current"
done
[[ $ELA -lt 10 ]] || fail "AC16 child-form stalled: ${ELA}s (bound 3s + kill grace 1s)"
pgrep -f 'sleep 61' >/dev/null 2>&1 &&
  fail "AC16 child-form left a grandchild behind: $(pgrep -fl 'sleep 61')"

# wrapper shape 2: 'sleep & wait' — the classic non-exec wrapper
full_current_home "$(remote_home x)"
cat >"$(remote_home x)/.local/bin/panewire" <<'EOF'
#!/bin/sh
sleep 62 &
wait
printf 'pw-deadbee\n'
EOF
chmod +x "$(remote_home x)/.local/bin/panewire"
SECONDS=0
run_fleet --only a --timeout 30
ELA=$SECONDS
[[ $RC -eq 3 ]] || fail "AC16 wait-form rc: want 3 got $RC :: $OUT"
assert_cell a panewire "unknown"
[[ "$(cell a panewire)" == *"tool timed out"* ]] ||
  fail "AC16 wait-form detail: $(cell a panewire)"
for t in scopefuel agent-skills handoffkeep; do
  assert_cell a "$t" "current"
done
[[ $ELA -lt 10 ]] || fail "AC16 wait-form stalled: ${ELA}s"
pgrep -f 'sleep 62' >/dev/null 2>&1 &&
  fail "AC16 wait-form left a grandchild behind: $(pgrep -fl 'sleep 62')"
pass "AC16 non-exec wrapper (child and sleep-&-wait forms) bounded; grandchild killed"

# ================================================================ AC17 (1007 B2)
# The probe's real worst case: five sequential tool calls on one host and
# every one ignoring TERM (git rev-parse slow but successful just under
# the bound, then status, panewire, handoffkeep --json and the go -m
# fallback all wedged). Invariant I-M2: the probe's worst case fits the
# host timeout — the run ends at most 25s after sh start and the local
# row does not read unreachable. Its own outer bound is --timeout 30.
reset_env
S_MAIN="$(sha40 s-main)"; HK_MAIN="$(sha40 hk-main)"
PW7="bb64078"; PW_MAIN="${PW7}$(sha40 pw-main | cut -c8-40)"
AS_MAIN="$(git -C "$CANON_AS" rev-parse HEAD)"
set_main scopefuel "$S_MAIN"; set_main agent-skills "$AS_MAIN"
set_main panewire "$PW_MAIN";   set_main handoffkeep "$HK_MAIN"
mk_home "$LOCAL_HOME"
give_scopefuel "$LOCAL_HOME" "$S_MAIN"
mkdir -p "$LOCAL_HOME/.agents/skills"
# fake git: rev-parse answers just under the bound; status wedges.
# trap '' TERM is inherited across exec, so every hang needs the KILL.
cat >"$LOCAL_HOME/.local/bin/git" <<EOF
#!/bin/sh
trap '' TERM
if [ "\$3" = "rev-parse" ]; then
  sleep 2
  printf '%s\n' "$AS_MAIN"
else
  exec sleep 71
fi
EOF
chmod +x "$LOCAL_HOME/.local/bin/git"
for t in panewire handoffkeep go; do
  case "$t" in panewire) n=72 ;; handoffkeep) n=73 ;; *) n=74 ;; esac
  printf '#!/bin/sh\ntrap "" TERM\nexec sleep %s\n' "$n" >"$LOCAL_HOME/.local/bin/$t"
  chmod +x "$LOCAL_HOME/.local/bin/$t"
done
SECONDS=0
run_fleet --only local --timeout 30
ELA=$SECONDS
echo "AC17 elapsed: ${ELA}s"
assert_cell local panewire "unknown"
assert_cell local handoffkeep "unknown"
assert_cell local scopefuel "current"
assert_cell local agent-skills "current"
[[ "$(cell local agent-skills)" == *"tool timed out"* ]] ||
  fail "AC17 agent-skills detail: $(cell local agent-skills)"
[[ "$(cell local panewire)" == *"tool timed out"* || \
   "$(cell local panewire)" == *"probe budget spent"* ]] ||
  fail "AC17 panewire detail: $(cell local panewire)"
[[ "$(cell local handoffkeep)" == *"tool timed out"* || \
   "$(cell local handoffkeep)" == *"probe budget spent"* ]] ||
  fail "AC17 handoffkeep detail: $(cell local handoffkeep)"
[[ $RC -eq 3 ]] || fail "AC17 rc: want 3 got $RC :: $OUT"
[[ $ELA -le 25 ]] || fail "AC17 probe worst case over the host window: ${ELA}s"
pgrep -f 'sleep 7[1-4]' >/dev/null 2>&1 &&
  fail "AC17 left wedged tools behind: $(pgrep -fl 'sleep 7[1-4]')"
pass "AC17 all five calls wedged ignoring TERM: local reachable, run ${ELA}s (<= 25s)"

# ================================================================ AC18 (1007 B3)
# A tool that reads stdin must get EOF at once — the probe script on
# stdin is not data. Runs the probe under 'sh -s' exactly as fleet-rev
# does and checks every key still prints (a tool eating the script would
# silently truncate every key after its own).
reset_env
mk_home "$LOCAL_HOME"
python3 - "$FLEET_REV" >"$TMP/probe.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
print(re.search(r'PROBE = r"""(.*?)"""', src, re.S).group(1))
PY
BASE_OUT="$(HOME="$LOCAL_HOME" sh -s <"$TMP/probe.sh")"
cat >"$LOCAL_HOME/.local/bin/panewire" <<'EOF'
#!/bin/sh
n=$(cat | wc -c | tr -d ' ')
printf '%s' "$n" >"$HOME/.fleet-rev/stdin-bytes"
printf 'pw-1234abc\n'
EOF
chmod +x "$LOCAL_HOME/.local/bin/panewire"
SECONDS=0
set +e
PROBE_OUT="$(HOME="$LOCAL_HOME" sh -s <"$TMP/probe.sh")"
PROBE_RC=$?
set -e
ELA=$SECONDS
[[ $PROBE_RC -eq 0 ]] || fail "AC18 probe rc: want 0 got $PROBE_RC :: $PROBE_OUT"
[[ "$(cat "$LOCAL_HOME/.fleet-rev/stdin-bytes" 2>/dev/null)" == "0" ]] ||
  fail "AC18 tool read stdin bytes: $(cat "$LOCAL_HOME/.fleet-rev/stdin-bytes" 2>/dev/null || echo missing)"
# Every key the baseline run printed must still print: a tool eating the
# probe script off stdin would silently truncate every key after its own.
for k in $(printf '%s\n' "$BASE_OUT" | sed 's/=.*//'); do
  printf '%s\n' "$PROBE_OUT" | grep -q "^$k=" ||
    fail "AC18 probe missing key $k :: $PROBE_OUT"
done
[[ "$(printf '%s\n' "$PROBE_OUT" | sed -n 's/^panewire.installed=//p')" == "1234abc" ]] ||
  fail "AC18 panewire.installed: $(printf '%s\n' "$PROBE_OUT" | grep panewire)"
[[ $ELA -lt 10 ]] || fail "AC18 probe stalled: ${ELA}s"
pass "AC18 tool reading stdin gets 0 bytes; every probe key still prints"

pass "all fleet-rev acceptance tests"
