#!/usr/bin/env bash
# hk 1941 contract tests for director/bin/area-propose (K2 area backfill
# proposal tool): propose is read-only and applies the packet's rule order
# (existing > files > title > project) with the smoke/throwaway exclusion;
# apply writes only confirmed rows through tasks set-area and refuses rows
# whose task changed area since the proposal. Fixtures live in
# tests/fixtures/area-propose/ (stub handoffkeep + stub gh, WRK_TEST_MODE=1).
set -euo pipefail
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/director/bin/area-propose"
HK="$ROOT/tests/fixtures/area-propose/handoffkeep"
GH="$ROOT/tests/fixtures/area-propose/gh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HK_DB="$TMP/hk-state.json"
HK_LOG="$TMP/hk-calls.log"
GH_LOG="$TMP/gh-calls.log"
GH_STUB="$TMP/gh-stub.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

run() {
  env HANDOFFKEEP_BIN="$HK" GH_BIN="$GH" HK_STATE="$HK_DB" HK_LOG="$HK_LOG" \
      GH_STUB_JSON="$GH_STUB" GH_LOG="$GH_LOG" "$TOOL" "$@"
}

# Seed the fixture db: one task per rule source plus exclusion, unknown,
# existing-area, tab-title and truncation-proof backlog filler tasks.
python3 - "$HK_DB" <<'PY'
import json, sys
tasks = {
    # backlog fillers push real rows past the 20-row bare-list truncation.
    **{str(i): {"id": i, "state": "backlog", "project": None,
               "title": f"filler task {i}", "area": None, "refs": {}}
       for i in range(1, 26)},
    "101": {"id": 101, "state": "backlog", "project": "ParkingArcade",
            "title": "Meshy blockout for garage kit", "area": None, "refs": {}},
    "102": {"id": 102, "state": "backlog", "project": "ParkingArcade",
            "title": "Fix vehicle steering feel", "area": None, "refs": {}},
    "103": {"id": 103, "state": "claimed", "project": None,
            "title": "Playwright web qa harness fix", "area": None, "refs": {}},
    "104": {"id": 104, "state": "merged", "project": "handoffkeep",
            "title": "Tasks queue backend work", "area": None, "refs": {}},
    "105": {"id": 105, "state": "in_progress", "project": "scopefuel",
            "title": "quota gate tuning", "area": None, "refs": {}},
    "106": {"id": 106, "state": "dropped", "project": None,
            "title": "smoke: throwaway spawn probe", "area": None, "refs": {}},
    "107": {"id": 107, "state": "backlog", "project": "fleet-ops",
            "title": "unmapped project work", "area": None, "refs": {}},
    "108": {"id": 108, "state": "backlog", "project": "agent-skills",
            "title": "wrk spawn bug", "area": "shell-wrk", "refs": {}},
    "109": {"id": 109, "state": "merged", "project": "ParkingArcade",
            "title": "car console panel",
            "area": None,
            "refs": {"pr": "https://github.com/mgh3326/ParkingArcade/pull/55"}},
    "110": {"id": 110, "state": "backlog", "project": None,
            "title": "docs only README update", "area": None, "refs": {}},
    "111": {"id": 111, "state": "needs_decision", "project": None,
            "title": "tab\ttitle with\ttabs", "area": None, "refs": {}},
    "112": {"id": 112, "state": "backlog", "project": "auto_trader",
            "title": "order router fix", "area": None, "refs": {}},
    # PR files split under 60% -> files rule must not fire; falls to project.
    "113": {"id": 113, "state": "merged", "project": "ParkingArcade",
            "title": "level flow tune", "area": None,
            "refs": {"pr": "https://github.com/mgh3326/ParkingArcade/pull/56"}},
    # hk 2012: shell-wrk title terms must beat docs/ops titles (hk 296, hk 1934
    # shapes); near-misses keep their docs/ops or no-area result.
    "120": {"id": 120, "state": "backlog", "project": None,
            "title": "SKILL.md wording for tester worktree handoff", "area": None,
            "refs": {}},
    "121": {"id": 121, "state": "backlog", "project": None,
            "title": "SKILL.md wording clarification", "area": None, "refs": {}},
    "122": {"id": 122, "state": "backlog", "project": None,
            "title": "trust_tripwire tests and install check", "area": None,
            "refs": {}},
    "123": {"id": 123, "state": "backlog", "project": None,
            "title": "plain install script refresh", "area": None, "refs": {}},
    "124": {"id": 124, "state": "backlog", "project": None,
            "title": "wrk round cap extension note", "area": None, "refs": {}},
    "125": {"id": 125, "state": "backlog", "project": None,
            "title": "funding round summary", "area": None, "refs": {}},
    # hk 2012 Korean keywords: one positive and one near-miss each.
    "126": {"id": 126, "state": "backlog", "project": None,
            "title": "콘솔 패널 정렬", "area": None, "refs": {}},
    "127": {"id": 127, "state": "backlog", "project": None,
            "title": "콘서트 일정 정리", "area": None, "refs": {}},
    "128": {"id": 128, "state": "backlog", "project": None,
            "title": "[hk /ui 홈 전환] 순서 재정렬", "area": None, "refs": {}},
    "129": {"id": 129, "state": "backlog", "project": None,
            "title": "홈 화면 디자인 검토", "area": None, "refs": {}},
    "130": {"id": 130, "state": "backlog", "project": None,
            "title": "함대 pane 전수 조사 보고", "area": None, "refs": {}},
    "131": {"id": 131, "state": "backlog", "project": None,
            "title": "조사 보고서 정리", "area": None, "refs": {}},
}
db = {"areas": ["blender", "unity", "web-qa", "ui-design", "image",
                "web-frontend", "go-backend", "python", "trading",
                "shell-wrk", "docs", "research", "ops"],
      "tasks": tasks}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(db, f)
PY

# gh stub map: pr/55 is all-blender files (files rule wins over the
# 'console' title keyword); pr/56 is under the 60% bar.
python3 - "$GH_STUB" <<'PY'
import json, sys
table = {
    "https://github.com/mgh3326/ParkingArcade/pull/55": {"files": [
        {"path": "Tools/blender/kit.py", "additions": 80, "deletions": 0},
        {"path": "Assets/car.fbx", "additions": 0, "deletions": 20}]},
    "https://github.com/mgh3326/ParkingArcade/pull/56": {"files": [
        {"path": "Assets/x.blend", "additions": 40, "deletions": 0},
        {"path": "src/Program.cs", "additions": 60, "deletions": 0}]},
}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(table, f)
PY

echo "== propose: rule order, per-state listing, exclusion, truncation =="

run propose --with-files >"$TMP/propose.tsv" 2>"$TMP/propose.err"

python3 - "$TMP/propose.tsv" <<'PY'
import csv, sys
rows = {r["id"]: r for r in csv.DictReader(open(sys.argv[1], newline=""), delimiter="\t")}
want = [
    # id, proposed_area, source, rule-prefix
    ("101", "blender", "title", "title:"),      # Meshy title beats ParkingArcade project
    ("102", "unity", "project", "project:"),    # ParkingArcade default
    ("103", "web-qa", "title", "title:"),       # playwright keyword, no project
    ("104", "go-backend", "project", "project:"),
    ("105", "python", "project", "project:"),
    ("106", "", "-", "excluded"),               # smoke/throwaway exclusion
    ("107", "", "-", "-"),                      # unmapped project, no keywords -> unknown
    ("108", "shell-wrk", "existing", "existing"),
    ("109", "blender", "files", "files:"),      # 100% blender lines beat 'console' title
    ("110", "docs", "title", "title:"),         # 'docs only' keyword
    ("111", "", "-", "-"),
    ("112", "trading", "project", "project:"),  # past the 20-row truncation wall
    ("113", "unity", "project", "project:"),    # files under 60% -> falls through
]
for tid, area, source, rule in want:
    r = rows.get(tid) or sys.exit(f"missing row for task {tid}")
    assert r["proposed_area"] == area, (tid, r["proposed_area"], area)
    assert r["source"] == source, (tid, r["source"], source)
    assert r["rule"].startswith(rule), (tid, r["rule"], rule)
    assert "\t" not in r["title"] and "\n" not in r["title"] and "\r" not in r["title"], tid
assert rows["108"]["current_area"] == "shell-wrk", rows["108"]
assert all(r["confirm"] == "" for r in rows.values()), "confirm column must be empty"
assert all(len(line.split("\t")) == 8
           for line in open(sys.argv[1]).read().splitlines()[1:]), "bad column count"
assert rows["106"]["source"] == "-", rows["106"]
PY

echo "== title rules: shell-wrk terms beat docs/ops, Korean keywords =="

python3 - "$TMP/propose.tsv" <<'PY'
import csv, sys
rows = {r["id"]: r for r in csv.DictReader(open(sys.argv[1], newline=""), delimiter="\t")}
want = [
    # id, proposed_area, rule-prefix; "" means no proposal
    ("120", "shell-wrk", "title:"),  # hk 296 shape: SKILL.md + tester worktree
    ("121", "docs", "title:"),       # docs-only SKILL.md title keeps docs
    ("122", "shell-wrk", "title:"),  # hk 1934 shape: tripwire + install
    ("123", "ops", "title:"),        # plain install title keeps ops
    ("124", "shell-wrk", "title:"),  # 'wrk round cap' phrase
    ("125", "", "-"),                # bare 'round' must not match
    ("126", "web-frontend", "title:"),  # 콘솔 positive
    ("127", "", "-"),                # 콘서트 near-miss
    ("128", "web-frontend", "title:"),  # 홈 전환 positive
    ("129", "", "-"),                # 홈 화면 near-miss
    ("130", "research", "title:"),   # 전수 조사 positive
    ("131", "", "-"),                # 조사 alone near-miss
]
for tid, area, rule in want:
    r = rows.get(tid) or sys.exit(f"missing row for task {tid}")
    assert r["proposed_area"] == area, (tid, r["title"], r["proposed_area"], area)
    if area:
        assert r["rule"].startswith(rule), (tid, r["rule"], rule)
    else:
        assert r["source"] == "-", (tid, r["source"])
PY
echo "PASS shell-wrk order and Korean keyword cases"

# Mutant invariant: propose never calls set-area (read-only).
! grep -q 'call tasks set-area' "$HK_LOG" 2>/dev/null \
  || fail "propose issued a set-area call"
# One tasks list --state call per state, no bare list.
[[ "$(grep -c 'call tasks list --state' "$HK_LOG")" -eq 9 ]] \
  || fail "expected 9 per-state list calls: $(grep -c 'call tasks list' "$HK_LOG")"
! grep -qE 'call tasks list( --limit|$)' "$HK_LOG" \
  || fail "bare tasks list call used"
# gh used exactly for the two PR-bearing tasks.
[[ "$(grep -c 'call pr view' "$GH_LOG")" -eq 2 ]] \
  || fail "gh pr view call count: $(cat "$GH_LOG")"
echo "PASS propose rule order + read-only + per-state + files"

echo "== propose without --with-files: files rule skipped =="
: >"$HK_LOG"; : >"$GH_LOG"
run propose >"$TMP/nofiles.tsv" 2>/dev/null
python3 - "$TMP/nofiles.tsv" <<'PY'
import csv, sys
rows = {r["id"]: r for r in csv.DictReader(open(sys.argv[1], newline=""), delimiter="\t")}
assert rows["109"]["source"] == "title" and rows["109"]["proposed_area"] == "web-frontend", rows["109"]
assert rows["113"]["source"] == "project" and rows["113"]["proposed_area"] == "unity", rows["113"]
PY
[[ ! -s "$GH_LOG" ]] || fail "gh called without --with-files"
echo "PASS files rule gated on --with-files"

echo "== propose with gh unavailable: skipped and noted =="
env HANDOFFKEEP_BIN="$HK" GH_BIN="$TMP/no-such-gh" HK_STATE="$HK_DB" \
    HK_LOG="$HK_LOG" "$TOOL" propose --with-files >"$TMP/nogh.tsv" 2>"$TMP/nogh.err"
grep -qi 'gh' "$TMP/nogh.err" || fail "gh-unavailable skip not noted"
python3 - "$TMP/nogh.tsv" <<'PY'
import csv, sys
rows = {r["id"]: r for r in csv.DictReader(open(sys.argv[1], newline=""), delimiter="\t")}
assert rows["109"]["source"] == "title" and rows["109"]["proposed_area"] == "web-frontend", rows["109"]
PY
echo "PASS gh unavailable -> noted skip, title still applies"

echo "== --sample N --seed S is deterministic and sized =="
run propose --sample 5 --seed 1938 >"$TMP/sample1.tsv"
run propose --sample 5 --seed 1938 >"$TMP/sample2.tsv"
cmp "$TMP/sample1.tsv" "$TMP/sample2.tsv" || fail "same seed differs"
[[ "$(wc -l <"$TMP/sample1.tsv")" -eq 6 ]] || fail "sample size: $(wc -l <"$TMP/sample1.tsv")"
run propose --sample 5 --seed 38 >"$TMP/sample3.tsv"
! cmp -s "$TMP/sample1.tsv" "$TMP/sample3.tsv" || fail "different seeds identical"
echo "PASS sample mode deterministic"

echo "== apply: only confirmed rows write; override; unknown refused =="

# Build the review file from real output; set confirm per row.
python3 - "$TMP/propose.tsv" "$TMP/reviewed.tsv" <<'PY'
import csv, sys
rows = list(csv.reader(open(sys.argv[1], newline=""), delimiter="\t"))
out = [rows[0]]
confirm = {"101": "yes", "102": "trading", "104": "bogus-area",
           "105": "yes", "106": "yes"}
for r in rows[1:]:
    r[-1] = confirm.get(r[0], "")
    out.append(r)
with open(sys.argv[2], "w", newline="") as f:
    csv.writer(f, delimiter="\t", lineterminator="\n").writerows(out)
PY

# Task 105 changes area between proposal and apply -> its row must be refused.
python3 - "$HK_DB" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
db["tasks"]["105"]["area"] = "ops"
json.dump(db, open(sys.argv[1], "w"))
PY

: >"$HK_LOG"
run apply --file "$TMP/reviewed.tsv" --by director-1 >"$TMP/apply.out" 2>"$TMP/apply.err"

python3 - "$HK_DB" "$HK_LOG" "$TMP/apply.out" "$TMP/apply.err" <<'PY'
import json, sys
db = json.load(open(sys.argv[1]))
log = open(sys.argv[2]).read()
out, err = open(sys.argv[3]).read(), open(sys.argv[4]).read()
assert db["tasks"]["101"]["area"] == "blender", "confirm=yes did not write"
assert db["tasks"]["102"]["area"] == "trading", "vocab override did not write"
assert db["tasks"]["103"]["area"] is None, "unconfirmed row written"
assert db["tasks"]["104"]["area"] is None, "unknown confirm value written"
assert db["tasks"]["105"]["area"] == "ops", "changed task overwritten"
assert db["tasks"]["106"]["area"] is None, "excluded task written"
assert db["tasks"]["107"]["area"] is None, "unknown task written"
assert db["tasks"]["108"]["area"] == "shell-wrk", "existing area clobbered"
assert db["tasks"]["109"]["area"] is None, "unconfirmed files row written"
assert db["tasks"]["110"]["area"] is None, "unconfirmed docs row written"
assert db["tasks"]["112"]["area"] is None, "unconfirmed trading row written"
assert db["tasks"]["113"]["area"] is None, "unconfirmed unity row written"
writes = [l for l in log.splitlines() if "call tasks set-area" in l]
assert len(writes) == 2, writes
assert any("set-area 101 blender --note area-propose " in l for l in writes), writes
assert any("set-area 102 trading --note area-propose " in l for l in writes), writes
assert "105" in err or "105" in out, "changed task refusal not reported"
assert "104" in err or "104" in out, "unknown confirm refusal not reported"
PY
echo "PASS apply writes only confirmed rows; refuses changed/unknown"

echo "== apply rerun is idempotent =="
: >"$HK_LOG"
run apply --file "$TMP/reviewed.tsv" --by director-1 >"$TMP/apply2.out" 2>/dev/null
! grep -q 'call tasks set-area' "$HK_LOG" \
  || fail "second apply re-wrote unchanged tasks"
grep -qi 'skip' "$TMP/apply2.out" || fail "second apply did not report skips"
echo "PASS apply idempotent"

echo "== apply rejects a file without the required header =="
printf 'id\tarea\n1\tyes\n' >"$TMP/bad.tsv"
if run apply --file "$TMP/bad.tsv" --by director-1 >/dev/null 2>"$TMP/bad.err"; then
  fail "bad header accepted"
fi
echo "PASS malformed review file refused"

echo "== propose output is stable TSV (8 columns, header) =="
head -1 "$TMP/propose.tsv" | grep -qx $'id\tproject\ttitle\tcurrent_area\tproposed_area\tsource\trule\tconfirm' \
  || fail "bad header: $(head -1 "$TMP/propose.tsv")"
awk -F'\t' 'NR>1 && NF!=8 {exit 1}' "$TMP/propose.tsv" || fail "row column count"
echo "PASS TSV shape"

echo "ALL TESTS PASSED"
