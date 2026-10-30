#!/usr/bin/env bash
# fleet-install acceptance tests. Fully hermetic: fake gh/ssh/scp fixtures,
# fixture HOMEs per host alias, and FLEET_INSTALL_BIN_DIR redirecting the
# local install. Covers: happy path with per-host archs and restart hooks,
# dry-run, a dead host (rc 1, other targets still install), a corrupt
# SHA256SUMS (rc 3, nothing installed) and the release-wait timeout (rc 3).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLEET_INSTALL="$ROOT/bin/fleet-install"
FIX="$ROOT/tests/fixtures/fleet-install"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

export FLEET_INSTALL_GH="$FIX/gh"
export FLEET_INSTALL_SSH="$FIX/ssh"
export FLEET_INSTALL_SCP="$FIX/scp"
export FLEET_INSTALL_SSH_LOG="$TMP/ssh.log"
export FLEET_INSTALL_SCP_LOG="$TMP/scp.log"
export FLEET_INSTALL_GH_LOG="$TMP/gh.log"
export FLEET_INSTALL_FAKE_DIR="$TMP/gh"
export FLEET_INSTALL_FAKE_ROOT="$TMP/homes"
export FLEET_INSTALL_BIN_DIR="$TMP/local-bin"
export FLEET_INSTALL_CONFIG="$TMP/fleet-install.toml"

local_arch() {
  printf '%s-%s' "$(uname -s | tr '[:upper:]' '[:lower:]')" \
    "$(uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)"
}

reset_env() {
  rm -rf "$FLEET_INSTALL_FAKE_DIR" "$FLEET_INSTALL_FAKE_ROOT" "$FLEET_INSTALL_BIN_DIR"
  mkdir -p "$FLEET_INSTALL_FAKE_DIR" "$FLEET_INSTALL_FAKE_ROOT"
  : >"$FLEET_INSTALL_SSH_LOG"; : >"$FLEET_INSTALL_SCP_LOG"; : >"$FLEET_INSTALL_GH_LOG"
  unset FLEET_INSTALL_FAKE_DEAD FLEET_INSTALL_FAKE_BADSHA \
    FLEET_INSTALL_FAKE_OMIT FLEET_INSTALL_FAKE_BROKEN 2>/dev/null || true
  : >"$FLEET_INSTALL_CONFIG"
}

# mk_release TOOL TAG ARCH... — one release manifest entry per arch.
mk_release() {
  local tool="$1"; shift
  local tag="$1"; shift
  local a
  : >"$FLEET_INSTALL_FAKE_DIR/$tool.release"
  for a in "$@"; do printf '%s-%s\n' "$tool" "$a" >>"$FLEET_INSTALL_FAKE_DIR/$tool.release"; done
  cat >"$FLEET_INSTALL_FAKE_DIR/$tool.run" <<EOF
[{"status":"completed","conclusion":"success","headBranch":"$tag"}]
EOF
}

mk_host() { # ALIAS ARCH
  local home="$FLEET_INSTALL_FAKE_ROOT/$1"
  mkdir -p "$home/.local/bin"
  printf '%s\n' "$2" >"$home/arch"
}

# ── 1. happy path: local + two hosts, restart hooks ─────────────────────
reset_env
LA="$(local_arch)"
mk_release runtug v9 "$LA" linux-arm64 linux-amd64
mk_host a linux-arm64
mk_host b linux-amd64
cat >"$FLEET_INSTALL_CONFIG" <<EOF
[tool.runtug.local]
restart = ["touch $TMP/local-restarted"]
[tool.runtug.host.b]
restart = ["touch \$HOME/b-restarted"]
EOF

out="$(FLEET_INSTALL_WAIT_TIMEOUT=5 FLEET_INSTALL_POLL_INTERVAL=1 \
  "$FLEET_INSTALL" runtug v9 --hosts a,b)"
[[ -x "$FLEET_INSTALL_BIN_DIR/runtug" ]] || fail "local binary missing"
[[ "$("$FLEET_INSTALL_BIN_DIR/runtug" --version)" == "runtug v9 (runtug-$LA)" ]] \
  || fail "local --version wrong"
[[ -x "$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug" ]] || fail "host a binary missing"
[[ -x "$FLEET_INSTALL_FAKE_ROOT/b/.local/bin/runtug" ]] || fail "host b binary missing"
[[ "$("$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug" --version)" == "runtug v9 (runtug-linux-arm64)" ]] \
  || fail "host a got the wrong arch artifact"
[[ "$("$FLEET_INSTALL_FAKE_ROOT/b/.local/bin/runtug" --version)" == "runtug v9 (runtug-linux-amd64)" ]] \
  || fail "host b got the wrong arch artifact"
# .new was renamed into place, not left behind
[[ ! -e "$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug.new" ]] || fail "host a .new left behind"
# scp uploaded the arm64 artifact to a and amd64 to b
grep -q "runtug-linux-arm64 a:" "$FLEET_INSTALL_SCP_LOG" || fail "scp log missing a arm64"
grep -q "runtug-linux-amd64 b:" "$FLEET_INSTALL_SCP_LOG" || fail "scp log missing b amd64"
# version printed per host
printf '%s' "$out" | grep -q "a: runtug v9" || fail "no version line for a"
printf '%s' "$out" | grep -q "b: runtug v9" || fail "no version line for b"
# restart hooks: local ran, b ran over ssh, a had none
[[ -f "$TMP/local-restarted" ]] || fail "local restart hook did not run"
[[ -f "$FLEET_INSTALL_FAKE_ROOT/b/b-restarted" ]] || fail "host b restart hook did not run"
if grep -q "touch .*a-restarted" "$FLEET_INSTALL_SSH_LOG"; then fail "unexpected restart on a"; fi
pass "happy path: local + hosts a,b with restarts"

# ── 2. dry-run installs nothing ──────────────────────────────────────────
reset_env
mk_release runtug v9 "$LA" linux-arm64
mk_host a linux-arm64
out="$("$FLEET_INSTALL" runtug v9 --hosts a --dry-run)"
printf '%s' "$out" | grep -q "dry-run" || fail "no dry-run output"
[[ ! -e "$FLEET_INSTALL_BIN_DIR/runtug" ]] || fail "dry-run installed locally"
[[ ! -e "$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug" ]] || fail "dry-run installed on a"
[[ ! -s "$FLEET_INSTALL_SCP_LOG" ]] || fail "dry-run ran scp"
pass "dry-run"

# ── 3. dead host -> rc 1, other targets still install ────────────────────
reset_env
mk_release runtug v9 "$LA" linux-arm64
mk_host a linux-arm64
mk_host b linux-arm64
export FLEET_INSTALL_FAKE_DEAD=b
set +e
out="$("$FLEET_INSTALL" runtug v9 --hosts a,b 2>&1)"
rc=$?
set -e
unset FLEET_INSTALL_FAKE_DEAD
[[ $rc -eq 1 ]] || fail "dead host should exit 1, got $rc"
[[ -x "$FLEET_INSTALL_BIN_DIR/runtug" ]] || fail "local install skipped after host failure"
[[ -x "$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug" ]] || fail "host a skipped after b failure"
printf '%s' "$out" | grep -q "failed targets: b" || fail "missing failed-targets line"
pass "dead host exits 1, rest still installed"

# ── 4. corrupt SHA256SUMS -> rc 3, nothing installed ─────────────────────
reset_env
mk_release runtug v9 "$LA" linux-arm64
mk_host a linux-arm64
export FLEET_INSTALL_FAKE_BADSHA=1
set +e
out="$("$FLEET_INSTALL" runtug v9 --hosts a 2>&1)"
rc=$?
set -e
unset FLEET_INSTALL_FAKE_BADSHA
[[ $rc -eq 3 ]] || fail "bad checksum should exit 3, got $rc"
[[ ! -e "$FLEET_INSTALL_BIN_DIR/runtug" ]] || fail "installed despite bad checksum"
[[ ! -e "$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug" ]] || fail "installed on a despite bad checksum"
pass "checksum failure exits 3 before installing"

# ── 5. release run never completes -> rc 3 timeout ───────────────────────
reset_env
printf 'runtug-%s\n' "$LA" >"$FLEET_INSTALL_FAKE_DIR/runtug.release"
printf '[{"status":"in_progress","conclusion":null}]\n' \
  >"$FLEET_INSTALL_FAKE_DIR/runtug.run"
set +e
out="$(FLEET_INSTALL_WAIT_TIMEOUT=1 FLEET_INSTALL_POLL_INTERVAL=1 \
  "$FLEET_INSTALL" runtug v9 2>&1)"
rc=$?
set -e
[[ $rc -eq 3 ]] || fail "wait timeout should exit 3, got $rc"
printf '%s' "$out" | grep -q "timed out" || fail "missing timeout message"
pass "release wait timeout exits 3"

# ── 6. missing artifact for a host's arch -> that host fails ─────────────
reset_env
mk_release runtug v9 "$LA" linux-amd64
mk_host a linux-arm64
set +e
out="$("$FLEET_INSTALL" runtug v9 --hosts a 2>&1)"
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "missing artifact should exit 1, got $rc"
printf '%s' "$out" | grep -q "no artifact for arch linux-arm64" \
  || fail "missing no-artifact message"
pass "missing artifact marks host failed"

# ── 7. artifact missing from SHA256SUMS -> refused ───────────────────────
reset_env
mk_release runtug v9 "$LA" linux-arm64
mk_host a linux-arm64
export FLEET_INSTALL_FAKE_OMIT=runtug-linux-arm64
set +e
out="$("$FLEET_INSTALL" runtug v9 --hosts a 2>&1)"
rc=$?
set -e
unset FLEET_INSTALL_FAKE_OMIT
[[ $rc -eq 1 ]] || fail "unlisted artifact should exit 1, got $rc"
printf '%s' "$out" | grep -q "not listed in SHA256SUMS" \
  || fail "missing not-listed message"
[[ ! -e "$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug" ]] \
  || fail "installed an artifact absent from SHA256SUMS"
pass "artifact absent from SHA256SUMS refused"

# ── 8. staged .new fails --version -> old binary kept ────────────────────
reset_env
mk_release runtug v9 "$LA" linux-arm64
mk_host a linux-arm64
printf '#!/bin/sh\necho "runtug v8 (runtug-linux-arm64)"\n' \
  >"$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug"
chmod 755 "$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug"
export FLEET_INSTALL_FAKE_BROKEN=runtug-linux-arm64
set +e
out="$("$FLEET_INSTALL" runtug v9 --hosts a 2>&1)"
rc=$?
set -e
unset FLEET_INSTALL_FAKE_BROKEN
[[ $rc -eq 1 ]] || fail "broken .new should exit 1, got $rc"
[[ "$("$FLEET_INSTALL_FAKE_ROOT/a/.local/bin/runtug" --version)" \
  == "runtug v8 (runtug-linux-arm64)" ]] \
  || fail "old binary was replaced by a broken .new"
pass "broken staged .new leaves the old binary in place"

echo "PASS all fleet-install tests"
