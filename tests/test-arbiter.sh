#!/usr/bin/env bash
# ROB-1199 stage 2 — arbiter admission-control acceptance tests.
# Every run is hermetic: XDG_DATA_HOME and ARBITER_INBOX_ROOT point into a temp
# dir, so the real ~/.local/share and ~/work/herdr-inbox are never touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARBITER="$ROOT/bin/arbiter"
SCOPEFUEL="$ROOT/tests/fixtures/scopefuel"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

export XDG_DATA_HOME="$TMP/xdg"
export ARBITER_INBOX_ROOT="$TMP/inbox"
export SCOPEFUEL_BIN="$SCOPEFUEL"
DB="$XDG_DATA_HOME/arbiter/state.db"
"$SCOPEFUEL" gate -m codex-max >"$TMP/gate.out"

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*" >&2; exit 1; }

# Run arbiter, capture stdout/stderr and the exit code without aborting the suite.
run() {
  set +e
  OUT="$("$ARBITER" "$@" 2>"$TMP/stderr")"
  RC=$?
  set -e
  ERR="$(cat "$TMP/stderr")"
}

expect_rc() {
  local want="$1"; shift
  run "$@"
  [[ "$RC" -eq "$want" ]] || fail "expected exit $want, got $RC for: arbiter $* :: $OUT $ERR"
}

# pycheck <json-text> [argv...] <<'PY' ... PY  — the heredoc is the checker script,
# the json arrives on the checker's stdin.
pycheck() {
  local json="$1"; shift
  cat >"$TMP/check.py"
  printf '%s' "$json" | python3 "$TMP/check.py" "$@"
}

jget() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
mtime() { python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$1"; }
restore_db() { cp "$TMP/good.db" "$DB"; rm -f "$DB-wal" "$DB-shm"; }

# ---------------------------------------------------------------- ⑤ fail-closed
# DB 없음: bootstrap 이 허용된 claim 을 뺀 모든 경로는 비-0 로 거부한다.
expect_rc 6 status
expect_rc 6 lease --job j --kind quota_pool --profile codex-max --gate-output "$TMP/gate.out"
expect_rc 6 gc
expect_rc 6 release --job j --resource pool --token t
expect_rc 6 event --job j --kind note
pass "fail-closed: missing db rejects status/lease/gc/release/event (exit 6)"

# ------------------------------------------------------------------- ① claim
expect_rc 0 claim --job j1 --lane live --t T2
[[ -f "$DB" ]] || fail "claim did not bootstrap the state db"
grep -q 'initialized new state db' <<<"$ERR" || fail "bootstrap was silent"
pass "claim bootstraps the db exactly once, and says so"

expect_rc 4 claim --job j1 --lane live --t T2
grep -q '이미 등록' <<<"$ERR" || fail "duplicate claim message missing"
expect_rc 4 claim --job j1 --lane other --t T3
pass "① duplicate claim rejected (exit 4); a different lane/t does not launder it"

expect_rc 2 claim --job j2 --lane live --t T9
pass "claim rejects a t level outside T0..T3"

# ------------------------------------------------------- ② concurrent contention
"$ARBITER" claim --job race-a --lane live --t T2 >/dev/null
"$ARBITER" claim --job race-b --lane live --t T2 >/dev/null
for job in race-a race-b; do
  (
    set +e
    "$ARBITER" lease --job "$job" --resource contended --kind path --json >"$TMP/$job.out" 2>&1
    echo $? >"$TMP/$job.rc"
  ) &
done
wait
rc_a="$(cat "$TMP/race-a.rc")"; rc_b="$(cat "$TMP/race-b.rc")"
winners=0
[[ "$rc_a" -eq 0 ]] && winners=$((winners + 1))
[[ "$rc_b" -eq 0 ]] && winners=$((winners + 1))
[[ "$winners" -eq 1 ]] || fail "expected exactly one winner, got rc_a=$rc_a rc_b=$rc_b"
if [[ "$rc_a" -eq 0 ]]; then loser="$rc_b"; else loser="$rc_a"; fi
[[ "$loser" -eq 3 ]] || fail "loser exited $loser, expected 3 (rc_a=$rc_a rc_b=$rc_b)"
pass "② concurrent lease: exactly one acquire wins, the other is denied (exit 3)"

# The winner holds it; a third job cannot take it while unexpired.
"$ARBITER" claim --job race-c --lane live --t T2 >/dev/null
expect_rc 3 lease --job race-c --resource contended --kind path
pass "② a held lease keeps refusing further acquires"

# ------------------------------------------------------------- ③ fencing token
"$ARBITER" claim --job fence --lane live --t T1 >/dev/null
tok_a="$("$ARBITER" lease --job fence --resource fenced --kind path --json | jget token)"
tok_b="$("$ARBITER" lease --job fence --resource fenced2 --kind path --json | jget token)"
[[ "$tok_a" != "$tok_b" ]] || fail "acquire reused a fencing token"
[[ "${tok_a%%-*}" -lt "${tok_b%%-*}" ]] || fail "fencing token is not monotonic"
pass "③ every acquire mints a new, monotonically increasing fencing token"

expect_rc 5 release --job fence --resource fenced --token "stale-token"
expect_rc 5 release --job race-c --resource fenced --token "$tok_a"
expect_rc 0 release --job fence --resource fenced --token "$tok_a"
expect_rc 5 release --job fence --resource fenced --token "$tok_a"
pass "③ stale token, wrong owner and replayed release are all rejected (exit 5)"

# --------------------------------------------------------- ④ expiry + audit
"$ARBITER" claim --job exp-a --lane live --t T1 >/dev/null
"$ARBITER" claim --job exp-b --lane live --t T1 >/dev/null
old_token="$("$ARBITER" lease --job exp-a --resource expiring --kind path --ttl-min 0 --json | jget token)"

run gc --json
[[ "$RC" -eq 0 ]] || fail "gc failed: $ERR"
pycheck "$OUT" <<'PY' || fail "gc did not transition the expired lease"
import json, sys
d = json.load(sys.stdin)
assert d["expired"] >= 1, d
assert d["retained"] == d["checked"], d          # transitioned, never deleted
assert any(t["resource"] == "expiring" for t in d["transitioned"]), d
PY
pycheck "$("$ARBITER" status --json)" <<'PY' || fail "gc deleted the expired lease row"
import json, sys
d = json.load(sys.stdin)
rows = [x for x in d["leases"] if x["resource"] == "expiring"]
assert rows and rows[0]["expired"] is True, d
assert [h for h in d["history"] if h["resource"] == "expiring" and h["state"] == "expired"], d
PY
pass "④ gc transitions expired leases to an audit state without deleting the row"

expect_rc 0 lease --job exp-b --resource expiring --kind path
pycheck "$("$ARBITER" status --json)" <<'PY' || fail "prior owner/token/expiry not preserved"
import json, sys
d = json.load(sys.stdin)
live = [x for x in d["leases"] if x["resource"] == "expiring"]
assert live and live[0]["job"] == "exp-b", live
hist = [h for h in d["history"] if h["resource"] == "expiring"]
assert {"expired", "superseded"} <= {h["state"] for h in hist}, hist
assert "exp-a" in {h["job"] for h in hist}, hist
assert all(h["token"].endswith("…") for h in d["history"]), "raw tokens leaked into status"
PY
pass "④ another job acquires after expiry; prior owner, token and expiry survive as audit"

expect_rc 5 release --job exp-a --resource expiring --token "$old_token"
pass "④ the superseded owner can no longer release the resource"

# ------------------------------------------------------------------ default TTL
"$ARBITER" claim --job ttl --lane live --t T1 >/dev/null
check_ttl() {
  local kind="$1" want="$2"
  pycheck "$("$ARBITER" lease --job ttl --resource "ttl-$kind" --kind "$kind" --json)" "$want" \
    <<'PY' || fail "default TTL for $kind is wrong"
import datetime as dt, json, sys
want = int(sys.argv[1])
d = json.load(sys.stdin)
delta = dt.datetime.fromisoformat(d["expires_at"]) - dt.datetime.fromisoformat(d["acquired_at"])
assert delta == dt.timedelta(minutes=want), (d, delta)
assert d["ttl_min"] == want, d
PY
}
check_ttl path 90
check_ttl linear_permit 30
pass "default TTL: path=90m, linear_permit=30m; quota_pool has no TTL"

# ------------------------------------------------- ⑨ event artifact + duplicate
"$ARBITER" claim --job ev --lane live --t T1 >/dev/null
events_dir="$ARBITER_INBOX_ROOT/ev/events"
[[ -f "$events_dir/00001-job.claim.json" ]] || fail "claim artifact missing"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$events_dir/00001-job.claim.json" \
  || fail "claim artifact is not valid json"
expect_rc 0 event --job ev --kind handoff --payload hello
[[ -f "$events_dir/00002-handoff.json" ]] || fail "event artifact missing"
[[ -z "$(find "$events_dir" -name '.tmp-*' -print -quit)" ]] || fail "temp artifact left behind"
pass "⑨ event artifacts land via atomic rename; no partial temp files remain"

expect_rc 0 event --job ev --kind explicit --seq 50
expect_rc 4 event --job ev --kind explicit --seq 50
[[ "$(find "$events_dir" -name '00050-*' | wc -l | tr -d ' ')" -eq 1 ]] \
  || fail "duplicate seq produced a second artifact"
pass "⑨ duplicate (job_id, seq) rejected (exit 4); no duplicate artifact written"

expect_rc 3 event --job nope --kind orphan
pass "⑨ events for an unclaimed job are refused"

# ---------------------------------------------- profile → pool via scopefuel
"$ARBITER" claim --job pool-a --lane live --t T1 >/dev/null
"$SCOPEFUEL" gate -m codex-max >"$TMP/gate.out"
run lease --job pool-a --kind quota_pool --profile codex-max --gate-output "$TMP/gate.out" --json
[[ "$RC" -eq 0 ]] || fail "profile lease failed: $ERR"
[[ "$(jget pool <<<"$OUT")" == "codex" ]] || fail "profile did not resolve to the scopefuel pool"
[[ "$(jget profile <<<"$OUT")" == "codex-max" ]] || fail "profile was not recorded"
[[ "$(jget resolved_from <<<"$OUT")" == "scopefuel:codex-max" ]] || fail "resolution provenance missing"
pass "quota pool resolved from scopefuel output, not from a wrk-side mapping"

"$ARBITER" claim --job pool-b --lane live --t T1 >/dev/null
expect_rc 0 lease --job pool-b --kind quota_pool --profile codex-max --gate-output "$TMP/gate.out"
pycheck "$("$ARBITER" status --json)" <<'PY' || fail "same quota pool did not record two jobs"
import json, sys
d = json.load(sys.stdin)
rows = [r for r in d["quota_pool_records"] if r["pool"] == "codex"]
assert {r["job_id"] for r in rows} >= {"pool-a", "pool-b"}, d
assert all(set(r) == {"job_id", "pool", "profile", "started_at"} for r in rows), rows
PY
pass "quota_pool is non-exclusive: two jobs record the same pool successfully"

"$ARBITER" claim --job pool-c --lane live --t T1 >/dev/null
"$ARBITER" claim --job pool-d --lane live --t T1 >/dev/null
for job in pool-c pool-d; do
  (
    set +e
    "$ARBITER" lease --job "$job" --kind quota_pool --profile codex-max \
      --gate-output "$TMP/gate.out" --json >"$TMP/$job.out" 2>&1
    echo $? >"$TMP/$job.rc"
  ) &
done
wait
[[ "$(cat "$TMP/pool-c.rc")" -eq 0 && "$(cat "$TMP/pool-d.rc")" -eq 0 ]] \
  || fail "concurrent quota_pool records did not both succeed"
pass "concurrent jobs can both record the same quota_pool"

printf 'gate allowed profile=codex-max\n' >"$TMP/nopool.out"
expect_rc 6 lease --job pool-b --kind quota_pool --profile codex-max --gate-output "$TMP/nopool.out"
"$SCOPEFUEL" gate -m opus >"$TMP/other.out"
expect_rc 6 lease --job pool-b --kind quota_pool --profile codex-max --gate-output "$TMP/other.out"
pass "gate output without a pool, or for another profile, is refused (exit 6)"

for mode in drift broken garbage; do
  export WRK_SCOPEFUEL_JSON_MODE="$mode"
  expect_rc 6 lease --job pool-b --kind quota_pool --profile codex-max --gate-output "$TMP/gate.out"
  unset WRK_SCOPEFUEL_JSON_MODE
done
pass "pool absent from scopefuel --json, or --json unusable, is fail-closed (exit 6)"

expect_rc 2 lease --job pool-b --kind path --profile codex-max
expect_rc 2 lease --job pool-b --kind quota_pool
expect_rc 2 lease --job pool-b --kind quota_pool --resource codex --profile codex-max
pass "lease usage errors are rejected (exit 2), never guessed"

# ------------------------------------------------------ quota record lifecycle
"$ARBITER" claim --job quota-live --lane live --t T1 >/dev/null
"$ARBITER" claim --job quota-dead --lane live --t T1 >/dev/null
expect_rc 0 lease --job quota-live --kind quota_pool --profile codex-max --gate-output "$TMP/gate.out"
expect_rc 0 lease --job quota-dead --kind quota_pool --profile codex-max --gate-output "$TMP/gate.out"
printf '%s\n' '{"result":{"agents":[{"name":"pool-a","agent_status":"working"},{"name":"pool-b","agent_status":"working"},{"name":"pool-c","agent_status":"working"},{"name":"pool-d","agent_status":"working"},{"name":"quota-live","agent_status":"working"}]}}' >"$TMP/agents.json"
run gc --herdr-agent-list "$TMP/agents.json" --json
[[ "$RC" -eq 0 ]] || fail "stale quota cleanup failed: $ERR"
pycheck "$OUT" <<'PY' || fail "stale cleanup did not report the dead job"
import json, sys
d = json.load(sys.stdin)
assert [r["job_id"] for r in d["stale_quota_pool"]] == ["quota-dead"], d
PY
pycheck "$("$ARBITER" status --json)" <<'PY' || fail "stale quota record remains"
import json, sys
d = json.load(sys.stdin)
assert {r["job_id"] for r in d["quota_pool_records"]} >= {"pool-a", "pool-b", "quota-live"}, d
assert "quota-dead" not in {r["job_id"] for r in d["quota_pool_records"]}, d
PY
[[ -f "$ARBITER_INBOX_ROOT/quota-dead/events/00003-quota_pool.stale_cleanup.json" ]] \
  || fail "stale cleanup event artifact missing"
expect_rc 0 release --job quota-live --resource codex --kind quota_pool
pass "normal quota release and herdr-list stale cleanup leave event evidence"

# ------------------------------------------------------------ ⑤ forced release
"$ARBITER" claim --job force --lane live --t T1 >/dev/null
force_token="$("$ARBITER" lease --job force --resource forced --kind path --json | jget token)"
run release --force --job force --resource forced --kind path --json
[[ "$RC" -eq 0 ]] || fail "forced release failed: $ERR"
[[ "$(jget forced <<<"$OUT")" == "True" ]] || fail "forced release did not report forced=true"
[[ -f "$ARBITER_INBOX_ROOT/force/events/00003-lease.release.force.json" ]] \
  || fail "forced release event artifact missing"
expect_rc 5 release --job force --resource forced --kind path --token "$force_token"
pass "release --force bypasses fencing only with a force event"

# ------------------------------------------------------- ⑧ read-only status
"$ARBITER" status >/dev/null
before="$(mtime "$DB")"
for _ in 1 2 3; do
  "$ARBITER" status >/dev/null
  "$ARBITER" status --json >/dev/null
  "$ARBITER" status --job j1 >/dev/null
  "$ARBITER" status --lane live >/dev/null
done
after="$(mtime "$DB")"
[[ "$before" == "$after" ]] || fail "repeated status changed the db mtime ($before -> $after)"
pass "⑧ repeated read-only status leaves the db mtime unchanged"

expect_rc 2 status --job j1 --lane live
pass "status refuses contradictory scoping"

# ------------------------------------------- ⑤ schema mismatch / permission
cp "$DB" "$TMP/good.db"
python3 - "$DB" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("UPDATE meta SET schema_version = 99 WHERE id = 1")
con.commit()
con.close()
PY
expect_rc 6 status
grep -q 'schema mismatch' <<<"$ERR" || fail "schema mismatch not reported: $ERR"
expect_rc 6 claim --job after-mismatch --lane live --t T1
expect_rc 6 lease --job j1 --resource anything --kind path
pass "⑤ schema mismatch is fail-closed on every command, including claim"

restore_db
chmod 000 "$DB"
expect_rc 6 status
expect_rc 6 lease --job j1 --resource anything --kind path
chmod u+rw "$DB"
pass "⑤ permission error is fail-closed (exit 6)"

# The db survives every rejection above.
expect_rc 0 status
pass "state db still usable after the fail-closed battery"

# A db moved without its WAL sidecars still reads, and still reads read-only.
restore_db
expect_rc 0 status
before="$(mtime "$DB")"
expect_rc 0 status
[[ "$before" == "$(mtime "$DB")" ]] || fail "read-only status wrote to a sidecar-less db"
pass "⑧ status reads a db that has no -wal/-shm sidecar without writing to it"

echo 'PASS test-arbiter'
