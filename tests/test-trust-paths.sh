#!/usr/bin/env bash
# tests/test-trust-paths.sh — hk 1454: wrk round commands and arbiter claim
# take the inbox, the arbiter DB and the handoffkeep binary from the passwd
# home outside WRK_TEST_MODE, and honour env overrides in test mode only under
# a temp root. The non-test-mode path runs a copy of bin/wrk (and bin/arbiter)
# whose passwd-home line names a fake home under TMP, so no case reads or
# writes the real passwd home.
# The A && B || fail form is intended: fail whenever either check is false.
# Mutant strings are literal source text, so they stay single-quoted.
# shellcheck disable=SC2015,SC2016
set -euo pipefail
# hk 1454: wrk and arbiter honour temp-path overrides on trust reads only here.
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

export ARBITER_INBOX_ROOT="$TMP/inbox"
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/xdg/config"
export XDG_CACHE_HOME="$TMP/xdg/cache"
export XDG_DATA_HOME="$TMP/xdg/data"
export XDG_STATE_HOME="$TMP/xdg/state"
export CODEX_HOME="$TMP/codex"
export TMPDIR="$TMP/tmp"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$TMPDIR"
export WRK_NO_SLEEP=1
export WRK_JOB_DELEGATE=0
export PANEWIRE_BIN="$TMP/absent-panewire"
export HANDOFFKEEP_BIN="$TMP/absent-handoffkeep"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }

# The fake passwd home and its canonical paths.
PW="$TMP/pw"
CANON_INBOX="$PW/work/herdr-inbox/jobs"
CANON_HK="$PW/.local/bin/handoffkeep"
mkdir -p "$CANON_INBOX" "$PW/.local/bin" "$TMP/bin" "$TMP/tests"

# Copies whose passwd-home lookup is the fake home. Everything else is the
# shipped code; the substitution must hit exactly one line in each.
sed "s|^WRK_TRUST_HOME = pwd.getpwuid(os.getuid()).pw_dir$|WRK_TRUST_HOME = \"$PW\"|" "$WRK" >"$TMP/bin/wrk"
sed "s|trust_paths_decide(os.environ, pwd.getpwuid(os.getuid()).pw_dir,|trust_paths_decide(os.environ, \"$PW\",|" \
  "$ROOT/bin/arbiter" >"$TMP/bin/arbiter"
chmod +x "$TMP/bin/wrk" "$TMP/bin/arbiter"
[[ "$(grep -c "^WRK_TRUST_HOME = \"$PW\"$" "$TMP/bin/wrk")" -eq 1 ]] || fail 'wrk passwd-home line not patched'
[[ "$(grep -c "trust_paths_decide(os.environ, \"$PW\"," "$TMP/bin/arbiter")" -eq 1 ]] || fail 'arbiter passwd-home line not patched'
PWRK="$TMP/bin/wrk"

TEST_REPO="$TMP/repo"
git init -q "$TEST_REPO"
git -C "$TEST_REPO" config user.name 'Trust Fixture'
git -C "$TEST_REPO" config user.email 'trust-fixture@example.invalid'
for n in 1 2 3 4; do
  printf 'commit %s\n' "$n" >"$TEST_REPO/c$n"
  git -C "$TEST_REPO" add "c$n"
  git -C "$TEST_REPO" commit -q -m "c$n"
done
H1="$(git -C "$TEST_REPO" rev-parse HEAD~3)"
H4="$(git -C "$TEST_REPO" rev-parse HEAD)"

mkjob() { # mkjob <jobs-root> <job> [rounds-used]
  local events="$1/$2/events" n
  mkdir -p "$events"
  cat >"$events/00001-job.claim.json" <<EOF
{"created_at":"2026-09-27T00:00:00Z","job_id":"$2","kind":"job.claim","payload":{"agent_label":"$2","owner_lane":"$2-lane","pane_id":"w:p1","parent_lane":"director-1","repo":"$TEST_REPO","role":"builder","t_level":"T2"},"seq":1}
EOF
  for ((n = 1; n <= ${3:-0}; n++)); do
    cat >"$events/0000$((n + 1))-job.round.json" <<EOF
{"created_at":"2026-09-27T00:0$n:00Z","job_id":"$2","kind":"job.round","round":$n,"head":"$H1","epoch":1}
EOF
  done
}
rounds_in() { find "$1" -name '*-job.round.json' | wc -l | tr -d ' '; }

# A handoffkeep stub that prints a director-1 grant and logs its calls.
mk_grant_hk() { # mk_grant_hk <path> <job>
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$1.calls"
printf '{"key":"x","session":"director-1","created_by":"director-1","body":"round-extension: job=$2 extra=2 by=director-1\\\\n"}'
EOF
  chmod +x "$1"
}

run() { # run <cmd...>: sets RC and OUT (stdout+stderr)
  set +e
  OUT="$("$@" 2>&1)"
  RC=$?
  set -e
}

# The canonical handoffkeep in the fake home: secure, and never grants.
cat >"$CANON_HK" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$CANON_HK.calls"
exit 1
EOF
chmod 755 "$CANON_HK"

# ── lever 1: ARBITER_INBOX_ROOT redirect (hk 1447 r1 N3) ─────────────────────
mkjob "$CANON_INBOX" jr 3
mkjob "$TMP/builder-inbox" jr 0
run env -u WRK_TEST_MODE ARBITER_INBOX_ROOT="$TMP/builder-inbox" "$PWRK" round open jr --head "$H4"
[[ "$RC" -eq 2 ]] || fail "inbox redirect not refused outside test mode (rc=$RC): $OUT"
[[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 1 ]] || fail "refusal is not one line: $OUT"
grep -F "ARBITER_INBOX_ROOT" <<<"$OUT" | grep -qF "$CANON_INBOX" || fail "refusal must name the variable and canonical path: $OUT"
[[ "$(rounds_in "$TMP/builder-inbox/jr/events")" -eq 0 && "$(rounds_in "$CANON_INBOX/jr/events")" -eq 3 ]] ||
  fail 'refused inbox redirect wrote a round'
for sub in "round status jr" "joined jr --pr u --head $H4 --report $TMP/none"; do
  # shellcheck disable=SC2086
  run env -u WRK_TEST_MODE ARBITER_INBOX_ROOT="$TMP/builder-inbox" "$PWRK" $sub
  [[ "$RC" -eq 2 ]] && grep -qF "$CANON_INBOX" <<<"$OUT" || fail "$sub followed the inbox override (rc=$RC): $OUT"
done
printf 'x\nVERDICT: PASS @%s\n' "$H4" >"$TMP/v.md"
run env -u WRK_TEST_MODE ARBITER_INBOX_ROOT="$TMP/builder-inbox" "$PWRK" round verdict jr --file "$TMP/v.md"
[[ "$RC" -eq 2 ]] && grep -qF "ARBITER_INBOX_ROOT" <<<"$OUT" || fail "round verdict followed the inbox override: $OUT"
[[ -z "$(find "$TMP/builder-inbox/jr/events" -name '*verdict*')" ]] || fail 'refused verdict wrote a record'
# The same override is honoured in test mode under TMPDIR, with one warning.
run env ARBITER_INBOX_ROOT="$TMP/builder-inbox" "$WRK" round open jr --head "$H4"
[[ "$RC" -eq 0 ]] && grep -q 'round=1' <<<"$OUT" || fail "test-mode temp inbox override refused (rc=$RC): $OUT"
grep -q '^wrk: warning: WRK_TEST_MODE=1: trust paths taken from ARBITER_INBOX_ROOT$' <<<"$OUT" ||
  fail "test-mode override printed no warning naming the variable: $OUT"
echo "PASS lever-inbox-root-refused-outside-test-mode-honoured-in-test-mode"

# ── lever 1b: HOME redirect with ARBITER_INBOX_ROOT unset ────────────────────
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT HOME="$TMP/home" "$PWRK" round status jr
[[ "$RC" -eq 2 ]] && grep -q '^wrk: HOME does not resolve to the canonical path' <<<"$OUT" ||
  fail "HOME redirect not refused (rc=$RC): $OUT"
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT HOME="$PW" "$PWRK" round status jr
[[ "$RC" -eq 0 ]] && grep -q 'rounds=3' <<<"$OUT" || fail "canonical HOME refused (rc=$RC): $OUT"
echo "PASS lever-home-refused-outside-test-mode"

# ── canonical equality after realpath: trailing slash, symlinked parent ──────
ln -s "$PW/work" "$TMP/worklink"
for value in "$CANON_INBOX/" "$TMP/worklink/herdr-inbox/jobs" "$PW/work/../work/herdr-inbox/jobs"; do
  run env -u WRK_TEST_MODE ARBITER_INBOX_ROOT="$value" "$PWRK" round status jr
  [[ "$RC" -eq 0 ]] && grep -q 'rounds=3' <<<"$OUT" || fail "canonical inbox spelled $value refused (rc=$RC): $OUT"
done
echo "PASS canonical-inbox-accepted-after-realpath"

# ── lever 3: HANDOFFKEEP_BIN stub grant (hk 1447 r2 S3) ──────────────────────
mk_grant_hk "$TMP/stub-hk" jr
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT HOME="$PW" HANDOFFKEEP_BIN="$TMP/stub-hk" \
  "$PWRK" round open jr --head "$H4" --extend hk:doc/grant
[[ "$RC" -eq 2 ]] || fail "HANDOFFKEEP_BIN stub not refused outside test mode (rc=$RC): $OUT"
grep -F "HANDOFFKEEP_BIN" <<<"$OUT" | grep -qF "$CANON_HK" || fail "refusal must name HANDOFFKEEP_BIN and the canonical path: $OUT"
[[ ! -e "$TMP/stub-hk.calls" && "$(rounds_in "$CANON_INBOX/jr/events")" -eq 3 ]] || fail 'refused stub grant ran the stub or wrote a round'
# The canonical binary itself is accepted when named explicitly.
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT HOME="$PW" HANDOFFKEEP_BIN="$CANON_HK" \
  "$PWRK" round open jr --head "$H4" --extend hk:doc/grant
[[ "$RC" -eq 2 ]] && grep -q 'approval record not found' <<<"$OUT" || fail "canonical HANDOFFKEEP_BIN not used (rc=$RC): $OUT"
grep -q 'doc get grant' "$CANON_HK.calls" || fail 'canonical handoffkeep was not the binary consulted'
rm -f "$CANON_HK.calls"
# Test mode: the temp stub is honoured and its grant extends the cap.
mkjob "$TMP/ti" jr 3
run env ARBITER_INBOX_ROOT="$TMP/ti" HANDOFFKEEP_BIN="$TMP/stub-hk" "$WRK" round open jr --head "$H4" --extend hk:doc/grant
[[ "$RC" -eq 0 ]] && grep -q 'round=4' <<<"$OUT" || fail "test-mode temp HANDOFFKEEP_BIN refused (rc=$RC): $OUT"
grep -q 'trust paths taken from ARBITER_INBOX_ROOT HANDOFFKEEP_BIN$' <<<"$OUT" || fail "warning must name both overrides: $OUT"
echo "PASS lever-handoffkeep-bin-refused-outside-test-mode-honoured-in-test-mode"

# ── lever 4: PATH-first handoffkeep shim, HANDOFFKEEP_BIN unset ──────────────
mkdir -p "$TMP/shim"
mk_grant_hk "$TMP/shim/handoffkeep" jr
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT -u HANDOFFKEEP_BIN HOME="$PW" PATH="$TMP/shim:$PATH" \
  "$PWRK" round open jr --head "$H4" --extend hk:doc/grant
[[ "$RC" -eq 2 ]] && grep -q 'approval record not found' <<<"$OUT" || fail "PATH shim grant not refused (rc=$RC): $OUT"
[[ ! -e "$TMP/shim/handoffkeep.calls" ]] || fail 'PATH shim was consulted outside test mode'
grep -q 'doc get grant' "$CANON_HK.calls" || fail 'canonical handoffkeep was not consulted instead of the PATH shim'
[[ "$(rounds_in "$CANON_INBOX/jr/events")" -eq 3 ]] || fail 'refused PATH shim grant wrote a round'
mkjob "$TMP/ts" jr 3
run env -u HANDOFFKEEP_BIN ARBITER_INBOX_ROOT="$TMP/ts" PATH="$TMP/shim:$PATH" "$WRK" round open jr --head "$H4" --extend hk:doc/grant
[[ "$RC" -eq 0 ]] && grep -q 'round=4' <<<"$OUT" || fail "test-mode temp PATH shim refused (rc=$RC): $OUT"
echo "PASS lever-path-handoffkeep-refused-outside-test-mode-honoured-in-test-mode"

# ── test mode: overrides outside the temp roots are refused ─────────────────
run env ARBITER_INBOX_ROOT="/nonexistent-wrk-1454/jobs" "$WRK" round status jr
[[ "$RC" -eq 2 ]] && grep -q 'ARBITER_INBOX_ROOT resolves outside the test temp roots' <<<"$OUT" ||
  fail "test-mode inbox outside temp roots not refused (rc=$RC): $OUT"
run env ARBITER_INBOX_ROOT="$TMP/../../../../../../../../../../nonexistent-wrk-1454" "$WRK" round status jr
[[ "$RC" -eq 2 ]] || fail "test-mode .. escape not refused (rc=$RC): $OUT"
ln -s /usr "$TMP/escape"
run env ARBITER_INBOX_ROOT="$TMP/ts" HANDOFFKEEP_BIN="$TMP/escape/bin/env" "$WRK" round open jr --head "$H4" --extend hk:doc/grant
[[ "$RC" -eq 2 ]] && grep -q 'HANDOFFKEEP_BIN resolves outside the test temp roots' <<<"$OUT" ||
  fail "test-mode HANDOFFKEEP_BIN outside temp roots not refused (rc=$RC): $OUT"
echo "PASS test-mode-override-outside-temp-roots-refused"

# ── insecure canonical handoffkeep ──────────────────────────────────────────
insecure() { # insecure <label>: round open --extend must refuse naming the canonical path
  run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT -u HANDOFFKEEP_BIN HOME="$PW" "$PWRK" round open jr --head "$H4" --extend hk:doc/grant
  [[ "$RC" -eq 2 ]] && grep -q "canonical handoffkeep $CANON_HK is" <<<"$OUT" || fail "$1 canonical handoffkeep not refused (rc=$RC): $OUT"
}
chmod 775 "$CANON_HK"; insecure group-writable
chmod 757 "$CANON_HK"; insecure world-writable
chmod 755 "$CANON_HK"
mv "$CANON_HK" "$CANON_HK.real"
insecure missing
foreign="$(python3 -c 'import os,sys
for p in ("/bin/sh", "/usr/bin/env", "/bin/ls"):
    if os.stat(p).st_uid != os.getuid(): print(p); break')"
[[ -n "$foreign" ]] || fail 'no foreign-owned file found for the symlink case'
ln -s "$foreign" "$CANON_HK"; insecure foreign-owned-symlink
rm -f "$CANON_HK"; mv "$CANON_HK.real" "$CANON_HK"
echo "PASS insecure-canonical-handoffkeep-refused"

# ── arbiter claim: the same rule ─────────────────────────────────────────────
run env ARBITER_INBOX_ROOT="/nonexistent-wrk-1454/jobs" "$ROOT/bin/arbiter" claim --job ac1 --agent-label a --lane a --t T1
[[ "$RC" -eq 2 ]] && grep -q 'ARBITER_INBOX_ROOT resolves outside the test temp roots' <<<"$OUT" ||
  fail "arbiter claim followed an inbox outside temp roots (rc=$RC): $OUT"
[[ ! -e "$XDG_DATA_HOME/arbiter/state.db" ]] || fail 'refused arbiter claim created the DB'
run "$ROOT/bin/arbiter" claim --job ac2 --agent-label a --lane a --t T1
[[ "$RC" -eq 0 ]] && grep -q 'trust paths taken from ARBITER_INBOX_ROOT XDG_DATA_HOME' <<<"$OUT" ||
  fail "arbiter claim refused temp overrides in test mode (rc=$RC): $OUT"
run env -u WRK_TEST_MODE ARBITER_INBOX_ROOT="$CANON_INBOX" XDG_DATA_HOME="$TMP/builder-data" "$TMP/bin/arbiter" claim --job ac3 --agent-label a --lane a --t T1
[[ "$RC" -eq 2 ]] && grep -F 'XDG_DATA_HOME' <<<"$OUT" | grep -qF "$PW/.local/share/arbiter/state.db" ||
  fail "arbiter claim followed XDG_DATA_HOME outside test mode (rc=$RC): $OUT"
[[ ! -e "$TMP/builder-data" && ! -e "$PW/.local/share" ]] || fail 'refused arbiter claim wrote a DB'
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT -u XDG_DATA_HOME HOME="$PW" "$TMP/bin/arbiter" claim --job ac4 --agent-label a --lane a --t T1
[[ "$RC" -eq 0 && -e "$PW/.local/share/arbiter/state.db" && -d "$CANON_INBOX/ac4/events" ]] ||
  fail "arbiter claim refused the canonical paths (rc=$RC): $OUT"
# hk 1454 r1 B1: an empty HOME is refused, and claim consumes the checked paths.
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT -u XDG_DATA_HOME HOME= "$TMP/bin/arbiter" claim --job ac5 --agent-label a --lane a --t T1
[[ "$RC" -eq 2 ]] && grep -q '^arbiter: HOME does not resolve to the canonical path' <<<"$OUT" ||
  fail "arbiter claim with an empty HOME was not refused (rc=$RC): $OUT"
# hk 1454 r1 B2: a passwd home that is a symlink still trips in test mode.
ln -s "$PW" "$TMP/pw-alias"
sed "s|trust_paths_decide(os.environ, pwd.getpwuid(os.getuid()).pw_dir,|trust_paths_decide(os.environ, \"$TMP/pw-alias\",|" \
  "$ROOT/bin/arbiter" >"$TMP/bin/arbiter-alias"
chmod +x "$TMP/bin/arbiter-alias"
run env TMPDIR="$PW" HOME="$PW" ARBITER_INBOX_ROOT="$CANON_INBOX" XDG_DATA_HOME="$PW/.local/share" \
  "$TMP/bin/arbiter-alias" claim --job ac6 --agent-label a --lane a --t T1
[[ "$RC" -eq 2 ]] && grep -q 'tripwire' <<<"$OUT" || fail "symlinked passwd home did not trip (rc=$RC): $OUT"
[[ ! -e "$CANON_INBOX/ac6" ]] || fail 'tripped claim wrote under the passwd home'
echo "PASS arbiter-claim-same-rule"

# ── mutants: each invariant must go RED when its check is removed ────────────
mutant() { # mutant <name> <from> <old> <new>: copy <from> with one exact substitution
  python3 - "$2" "$TMP/bin/wrk-$1" "$3" "$4" <<'PY'
import os, sys
src, dst, old, new = sys.argv[1:]
text = open(src, encoding="utf-8").read()
assert text.count(old) == 1, (dst, text.count(old))
open(dst, "w", encoding="utf-8").write(text.replace(old, new))
os.chmod(dst, 0o755)
PY
}
# 1. round open without the override check follows ARBITER_INBOX_ROOT again.
mutant skip-open-check "$PWRK" \
  '  if [[ -n "$extend" ]]; then wrk_trust_enter inbox,handoffkeep; else wrk_trust_enter inbox; fi' ''
mkjob "$TMP/m1" jm 0
run env -u WRK_TEST_MODE ARBITER_INBOX_ROOT="$TMP/m1" "$TMP/bin/wrk-skip-open-check" round open jm --head "$H4"
[[ "$RC" -eq 0 && "$(rounds_in "$TMP/m1/jm/events")" -eq 1 ]] ||
  fail "mutant skip-open-check did not turn the inbox redirect repro RED (rc=$RC): $OUT"
# 2. the grant fetch honouring HANDOFFKEEP_BIN outside test mode lets the stub grant.
mutant hk-env "$PWRK" \
  $'round_approval_fetch() {\n  local ref="$1" handoffkeep out rc=0\n  handoffkeep="$WRK_TRUST_HANDOFFKEEP"' \
  $'round_approval_fetch() {\n  local ref="$1" handoffkeep out rc=0\n  handoffkeep="$(command -v "${HANDOFFKEEP_BIN:-handoffkeep}" 2>/dev/null || true)"'
mutant hk-env-decide "$TMP/bin/wrk-hk-env" \
  '                if not found or real(found) != chosen:' '                if False:'
run env -u WRK_TEST_MODE -u ARBITER_INBOX_ROOT HOME="$PW" HANDOFFKEEP_BIN="$TMP/stub-hk" \
  "$TMP/bin/wrk-hk-env-decide" round open jr --head "$H4" --extend hk:doc/grant
[[ "$RC" -eq 0 ]] && grep -q 'round=4' <<<"$OUT" ||
  fail "mutant hk-env did not turn the stub-grant repro RED (rc=$RC): $OUT"
# 3. test mode accepting a path outside the temp roots.
mutant any-root "$WRK" \
  '        if not any(under(resolved, root) for root in allowed):' '        if False:'
run env ARBITER_INBOX_ROOT="/nonexistent-wrk-1454/jobs" "$TMP/bin/wrk-any-root" round status jr
[[ "$RC" -eq 0 ]] || fail "mutant any-root did not turn the outside-temp-root case RED (rc=$RC): $OUT"
echo "PASS mutants-go-red"

echo "ALL PASS test-trust-paths"
