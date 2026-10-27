#!/usr/bin/env bash
# hk 2097: wrk artifacts move — copy a source tree as-is into a Drive folder
# in batches, confirm each batch uploaded through fpbulk (two reads >= 2 min
# apart with a DriveFS freshness guard), evict the Drive-folder copy, and
# record path/bytes/sha256 in hk. The mover never deletes a source original.
#
# Every Drive/fleet dependency is a stub under $TMP: fpbulk answers scripted
# per-path flags, handoffkeep/panewire/ssh/rsync are fixture binaries, the
# clock is a file (WRK_ARTIFACTS_TIME_FILE: now() reads it, sleep() advances
# it), and the Drive folder + DriveFS log dir are plain temp dirs.
set -euo pipefail
export WRK_TEST_MODE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WRK="$ROOT/bin/wrk"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/xdg-data" XDG_CONFIG_HOME="$TMP/xdg-config" XDG_STATE_HOME="$TMP/xdg-state" XDG_CACHE_HOME="$TMP/xdg-cache"
export ARBITER_INBOX_ROOT="$TMP/inbox/jobs"
export WRK_HOSTS_CONFIG="$TMP/hosts.toml"
export WRK_ARTIFACTS_TIME_FILE="$TMP/fake-now"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$ARBITER_INBOX_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file() { [[ -f "$1" ]] || fail "expected file $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "unexpected file $1"; }

# ---------------------------------------------------------------------------
# stub binaries
# ---------------------------------------------------------------------------

# fpbulk stub: per-path scripted flags. Specs live in $FPBULK_DIR/spec/<hash>
# where hash = sha256(path) and the file holds one of:
#   01 | 11 | 10 | ?? | omit | garbage | seq:f1,f2,...
# "seq" advances the flag on each *status* call naming that path (clamps at
# the last entry). Evict specs in $FPBULK_DIR/evict/<hash>: "err" prints
# err\tpath; "post:11" prints ok but the path keeps reading 11 (evict that
# never takes); anything else prints ok\tpath and rewrites the status spec
# to 10 (a real evict leaves 10). A hook file $FPBULK_DIR/on_status, when
# present, runs per status call with CALL=<status call number>.
write_fpbulk_stub() {
  mkdir -p "$FPBULK_DIR/spec" "$FPBULK_DIR/evict"
  cat >"$FPBULK" <<'PY'
#!/usr/bin/env python3
import hashlib, os, subprocess, sys
D = os.environ["FPBULK_DIR"]
def h(p): return hashlib.sha256(p.encode()).hexdigest()
def spec(kind, p):
    try:
        with open(os.path.join(D, kind, h(p)), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""
mode = sys.argv[1] if len(sys.argv) > 1 else "status"
paths = [l for l in sys.stdin.read().splitlines() if l]
if mode == "status":
    callfile = os.path.join(D, "status-calls")
    try:
        n = int(open(callfile).read().strip())
    except (OSError, ValueError):
        n = 0
    n += 1
    with open(callfile, "w") as f:
        f.write(str(n))
    hook = os.path.join(D, "on_status")
    if os.path.exists(hook):
        subprocess.run(["bash", hook], env={**os.environ, "CALL": str(n)}, check=False)
    with open(os.path.join(D, "calls.log"), "a") as log:
        log.write("status\t" + ",".join(paths) + "\n")
    for p in paths:
        s = spec("spec", p) or "11"
        if s == "omit":
            continue
        if s == "garbage":
            print("not a status line " + p, flush=True)
            continue
        if s.startswith("seq:"):
            seq = s[4:].split(",")
            s = seq[min(n - 1, len(seq) - 1)]
        print(s + "\t" + p, flush=True)
elif mode == "evict":
    with open(os.path.join(D, "calls.log"), "a") as log:
        log.write("evict\t" + ",".join(paths) + "\n")
    for p in paths:
        e = spec("evict", p) or "ok"
        if e == "err":
            print("err\t" + p, flush=True)
            continue
        print("ok\t" + p, flush=True)
        if e != "post:11":
            with open(os.path.join(D, "spec", h(p)), "w") as f:
                f.write("10")
PY
  chmod +x "$FPBULK"
}

# handoffkeep stub: doc put copies --file into $HK_DIR/docs and logs; doc get
# prints the stored body as an hk JSON envelope. Every call logs argv.
write_hk_stub() {
  mkdir -p "$HK_DIR/docs"
  cat >"$HK" <<'PY'
#!/usr/bin/env python3
import json, os, sys
D = os.environ["HK_STUB_DIR"]
argv = sys.argv[1:]
with open(os.path.join(D, "argv.log"), "a") as f:
    f.write("\0".join(argv) + "\n")
mode = os.environ.get("HK_STUB_MODE", "ok")
if mode == "fail":
    print("stub failure\nsecond line", file=sys.stderr)
    sys.exit(7)
if mode == "sleep":
    import time
    time.sleep(5)
if len(argv) >= 2 and argv[0] == "doc" and argv[1] in ("put", "get"):
    opts = {}
    i = 2
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            opts[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    key = opts.get("key", "")
    safe = key.replace("/", "_")
    if argv[1] == "put":
        with open(opts["file"], "rb") as f:
            body = f.read()
        with open(os.path.join(D, "docs", safe), "wb") as f:
            f.write(body)
        print(json.dumps({"changed": True, "document": {"key": key}}))
    else:
        try:
            with open(os.path.join(D, "docs", safe), "rb") as f:
                body = f.read().decode()
        except OSError:
            print("handoffkeep: not_found", file=sys.stderr)
            sys.exit(1)
        print(json.dumps({"key": key, "body": body}))
else:
    print("handoffkeep stub: unsupported " + " ".join(argv), file=sys.stderr)
    sys.exit(2)
PY
  chmod +x "$HK"
}

write_panewire_stub() {
  cat >"$PANEWIRE" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >>"$PANEWIRE_LOG"
printf '\0' >>"$PANEWIRE_LOG"
exit "${PANEWIRE_RC:-0}"
SH
  chmod +x "$PANEWIRE"
}

# ssh stub: serves only the remote-inventory call `ssh <host> python3 - SRC
# EXCLJSON` — the remote script arrives on stdin and runs locally against SRC
# (which is a real temp path in this suite). Any other argv fails 255 so a
# write-capable remote command can never slip through unobserved.
write_ssh_stub() {
  cat >"$SSH" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >>"$SSH_LOG"; printf '\0' >>"$SSH_LOG"
args=("$@")
n=$#
if [[ " $* " == *" python3 - "* ]]; then
  cat >"$SSH_DIR/remote-script.py"
  exec python3 "$SSH_DIR/remote-script.py" "${args[$((n-2))]}" "${args[$((n-1))]}"
fi
exit 255
SH
  chmod +x "$SSH"
}

# rsync stub: copies `--files-from` listed paths from <host>:<src>/ into the
# dest dir, refusing outright on --delete (the remote must never be written
# or pruned). --from0 means NUL-separated stdin.
write_rsync_stub() {
  cat >"$RSYNC" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >>"$RSYNC_LOG"; printf '\0' >>"$RSYNC_LOG"
for a in "$@"; do [[ "$a" == --delete* ]] && { echo "rsync stub: --delete refused" >&2; exit 23; }; done
args=("$@")
dst="${args[$(($#-1))]}"
src="" files_from="" from0=0
prev=""
for a in "$@"; do
  case "$a" in
    --files-from=*) files_from="${a#--files-from=}" ;;
    --from0) from0=1 ;;
    *:*) [[ "$a" != -* && "$prev" != "-e" ]] && src="${a#*:}" ;;
  esac
  prev="$a"
done
src="${src%/}"
[[ -n "$src" && -d "$src" ]] || { echo "rsync stub: no remote src in argv" >&2; exit 23; }
# stdin carries the --files-from list; stash it before the heredoc takes stdin.
listfile="$(mktemp)"
cat >"$listfile"
python3 - "$src" "$dst" "$from0" "$listfile" <<'PY'
import os, shutil, sys
src, dst, from0, listfile = sys.argv[1:5]
data = open(listfile, "rb").read()
rels = [p.decode() for p in (data.split(b"\0") if from0 == "1" else data.splitlines()) if p]
for rel in rels:
    s, d = os.path.join(src, rel), os.path.join(dst, rel)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copy2(s, d)
PY
rm -f "$listfile"
SH
  chmod +x "$RSYNC"
}

# ---------------------------------------------------------------------------
# case plumbing
# ---------------------------------------------------------------------------

CASE=""
# reset_case NAME: fresh SRC, DRIVE, stub dirs, hosts.toml.
reset_case() {
  CASE="$1"
  SRC="$TMP/$1/src"; DRIVE="$TMP/$1/drive"; DEST=""
  STATEDIR="$TMP/$1/state"; SCRATCH="$TMP/$1/scratch"
  LOGDIR="$TMP/$1/drivefs-logs"; APPFLAG="$TMP/$1/app-up"
  FPBULK="$TMP/$1/fpbulk"; FPBULK_DIR="$TMP/$1/fpbulk.d"
  HK="$TMP/$1/handoffkeep"; HK_DIR="$TMP/$1/hk.d"
  PANEWIRE="$TMP/$1/panewire"; PANEWIRE_LOG="$TMP/$1/panewire.argv"
  SSH="$TMP/$1/ssh"; SSH_DIR="$TMP/$1/ssh.d"; SSH_LOG="$TMP/$1/ssh.argv"
  RSYNC="$TMP/$1/rsync"; RSYNC_LOG="$TMP/$1/rsync.argv"
  OUT="$TMP/$1/out.txt"; ERR="$TMP/$1/err.txt"
  mkdir -p "$SRC" "$DRIVE" "$STATEDIR" "$SCRATCH" "$LOGDIR" "$FPBULK_DIR" "$HK_DIR" "$SSH_DIR"
  : >"$PANEWIRE_LOG"
  printf '1000000000\n' >"$WRK_ARTIFACTS_TIME_FILE"
  touch "$APPFLAG"
  python3 - "$LOGDIR/drive_fs.txt" "$WRK_ARTIFACTS_TIME_FILE" <<'PY'
import os, sys
p, tf = sys.argv[1:3]
open(p, "a").close()
t = float(open(tf).read())
os.utime(p, (t, t))
PY
  write_fpbulk_stub
  write_hk_stub
  write_panewire_stub
  write_ssh_stub
  write_rsync_stub
  write_hosts_toml 1000000 50
}

write_hosts_toml() {
  # write_hosts_toml BATCH_BYTES BATCH_FILES [STALE_MINUTES]
  local bb="$1" bf="$2" stale="${3:-60000}"
  cat >"$WRK_HOSTS_CONFIG" <<EOF
[artifacts]
drive_folder = "$DRIVE"
fpbulk = "$FPBULK"
batch_bytes = $bb
batch_files = $bf
poll_seconds = 30
confirm_timeout_seconds = 300
confirm_gap_seconds = 120
stale_minutes = $stale
drivefs_log_dir = "$LOGDIR"
app_check = "test -f $APPFLAG"
state_dir = "$STATEDIR"
scratch_dir = "$SCRATCH"
exclude = [".env", "*.env", ".env.*", "auth.json", "*token*", "*secret*", "Cookies", "Login Data", ".DS_Store"]
EOF
}

mk_src() { mkdir -p "$(dirname "$SRC/$1")"; printf '%s\n' "$2" >"$SRC/$1"; }

MOVE_RC=0
# run_move [wrk artifacts move args...]: never aborts on nonzero exit.
run_move() {
  local free="${WRK_ARTIFACTS_FREE_BYTES:-}"
  set +e
  if [[ -n "$free" ]]; then
    env -u ARBITER_JOB -u HK_TASK_ID \
      HANDOFFKEEP_BIN="$HK" PANEWIRE_BIN="$PANEWIRE" PANEWIRE_LOG="$PANEWIRE_LOG" \
      WRK_SSH_BIN="$SSH" SSH_LOG="$SSH_LOG" SSH_DIR="$SSH_DIR" \
      WRK_RSYNC_BIN="$RSYNC" RSYNC_LOG="$RSYNC_LOG" \
      FPBULK_DIR="$FPBULK_DIR" HK_STUB_DIR="$HK_DIR" \
      HK_STUB_MODE="${HK_STUB_MODE:-ok}" WRK_ARTIFACTS_HK_TIMEOUT_S="${WRK_ARTIFACTS_HK_TIMEOUT_S:-30}" \
      WRK_ARTIFACTS_FREE_BYTES="$free" \
      "$WRK" artifacts move "$@" >"$OUT" 2>"$ERR"
  else
    env -u ARBITER_JOB -u HK_TASK_ID \
      HANDOFFKEEP_BIN="$HK" PANEWIRE_BIN="$PANEWIRE" PANEWIRE_LOG="$PANEWIRE_LOG" \
      WRK_SSH_BIN="$SSH" SSH_LOG="$SSH_LOG" SSH_DIR="$SSH_DIR" \
      WRK_RSYNC_BIN="$RSYNC" RSYNC_LOG="$RSYNC_LOG" \
      FPBULK_DIR="$FPBULK_DIR" HK_STUB_DIR="$HK_DIR" \
      HK_STUB_MODE="${HK_STUB_MODE:-ok}" WRK_ARTIFACTS_HK_TIMEOUT_S="${WRK_ARTIFACTS_HK_TIMEOUT_S:-30}" \
      "$WRK" artifacts move "$@" >"$OUT" 2>"$ERR"
  fi
  MOVE_RC=$?
  set -e
}

# fp_spec REL SPEC — set the fpbulk status spec for the dest copy of a rel.
fp_hash() { python3 -c 'import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }
fp_spec() { printf '%s' "$2" >"$FPBULK_DIR/spec/$(fp_hash "$DEST/$1")"; }
fp_evict() { printf '%s' "$2" >"$FPBULK_DIR/evict/$(fp_hash "$DEST/$1")"; }
fp_calls() { if [[ -f "$FPBULK_DIR/calls.log" ]]; then cat "$FPBULK_DIR/calls.log"; fi; }
fp_evict_calls() { fp_calls | grep -c '^evict' || true; }
emit_count() { tr '\0' '\n' <"$PANEWIRE_LOG" | grep -c '^emit$' || true; }

record_doc() {
  [[ -f "$HK_DIR/docs/artifacts_$1" ]] || fail "no record doc artifacts_$1"
  cat "$HK_DIR/docs/artifacts_$1"
}

tree_sig() {
  python3 - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
rows = []
for r, ds, fs in os.walk(root):
    ds.sort()
    for f in sorted(fs):
        p = os.path.join(r, f)
        rel = os.path.relpath(p, root)
        with open(p, "rb") as fh:
            h = hashlib.sha256(fh.read()).hexdigest()
        rows.append("%s\t%d\t%s" % (rel, os.path.getsize(p), h))
print("\n".join(rows))
PY
}

# ---------------------------------------------------------------------------
# usage and configuration refusals
# ---------------------------------------------------------------------------

# A1: help names the four phases and the no-source-delete rule.
"$WRK" artifacts --help >"$TMP/a1.out" 2>&1 || fail "artifacts --help rc"
grep -q 'move' "$TMP/a1.out" || fail "artifacts --help lacks move"
"$WRK" artifacts move --help >"$TMP/a1m.out" 2>&1 || fail "move --help rc"
for w in batch confirm evict record; do
  grep -qi "$w" "$TMP/a1m.out" || fail "move --help lacks '$w'"
done
grep -qi 'never.*source' "$TMP/a1m.out" || fail "move --help lacks source-original rule"
echo "PASS a1 help"

# A2: no [artifacts] config -> refuse even for dry-run.
reset_case a2
mkdir -p "$SRC/sub"; mk_src a.txt hello; mk_src sub/b.txt world
: >"$WRK_HOSTS_CONFIG"
run_move "$SRC" --dest "$DRIVE/mbp/ds"
[[ "$MOVE_RC" -eq 2 ]] || fail "a2: expected rc 2, got $MOVE_RC"
grep -qi 'drive_folder\|fpbulk\|artifacts' "$ERR" || fail "a2: refusal should name the missing config"
echo "PASS a2 no-config refusal"

# A3: config without fpbulk -> refuse.
reset_case a3
mk_src a.txt hello
cat >"$WRK_HOSTS_CONFIG" <<EOF
[artifacts]
drive_folder = "$DRIVE"
EOF
run_move "$SRC" --dest "$DRIVE/mbp/ds"
[[ "$MOVE_RC" -eq 2 ]] || fail "a3: expected rc 2, got $MOVE_RC"
grep -qi 'fpbulk' "$ERR" || fail "a3: refusal should name fpbulk"
echo "PASS a3 no-fpbulk refusal"

# A4: dest outside drive_folder -> refuse.
reset_case a4
mk_src a.txt hello
run_move "$SRC" --dest "$TMP/$CASE/elsewhere/ds"
[[ "$MOVE_RC" -eq 2 ]] || fail "a4: expected rc 2, got $MOVE_RC"
echo "PASS a4 dest-outside-drive refusal"

# ---------------------------------------------------------------------------
# dry-run
# ---------------------------------------------------------------------------

reset_case dry
mk_src a.txt alpha; mk_src sub/b.txt beta; mk_src c.txt gamma
DEST="$DRIVE/mbp/ds"
run_move "$SRC" --dest "$DEST"
[[ "$MOVE_RC" -eq 0 ]] || fail "dry: rc $MOVE_RC $(tail -2 "$ERR")"
grep -qi 'dry' "$OUT" || fail "dry: output should mark dry-run"
grep -q 'files=3' "$OUT" || fail "dry: files count missing ($(cat "$OUT"))"
assert_no_file "$DEST/a.txt"
[[ -z "$(fp_calls)" ]] || fail "dry: fpbulk must not run"
[[ ! -s "$HK_DIR/argv.log" ]] || fail "dry: hk must not run"
[[ -z "$(find "$STATEDIR" -type f 2>/dev/null)" ]] || fail "dry: state dir must stay empty"
echo "PASS dry-run"

# ---------------------------------------------------------------------------
# case functions reused by the mutant section
# ---------------------------------------------------------------------------

# full-run case used by mutants: two batches, each copy -> 01 -> 11 -> evict.
case_full() {
  reset_case "$1"
  write_hosts_toml 1000000 2
  mk_src f1.txt alpha; mk_src f2.txt beta; mk_src f3.txt gamma; mk_src f4.txt delta
  mk_src sub/f5.txt epsilon
  DEST="$DRIVE/mbp/ds"
  for r in f1.txt f2.txt f3.txt f4.txt sub/f5.txt; do
    fp_spec "$r" 'seq:01,11'
  done
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 0 ]] || return 1
  [[ "$(fp_evict_calls)" -eq 3 ]] || return 1
  # each batch's evict precedes the next batch's first status call; a status
  # call between evict i and evict i+1 may name only batch i (post-evict
  # re-read) or batch i+1 (confirm) files — never a later batch.
  python3 - "$FPBULK_DIR/calls.log" "$DEST" <<'PY' || return 1
import sys
lines = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1])]
dest = sys.argv[2]
evict_idx = [i for i, (m, _) in enumerate(lines) if m == "evict"]
assert len(evict_idx) == 3, lines
batches = [["f1.txt", "f2.txt"], ["f3.txt", "f4.txt"], ["sub/f5.txt"]]
for i, ei in enumerate(evict_idx):
    evict_paths = lines[ei][1].split(",")
    assert sorted(evict_paths) == sorted(dest + "/" + r for r in batches[i]), evict_paths
    lo = evict_idx[i - 1] + 1 if i else 0
    allowed = set(dest + "/" + r for r in batches[i])
    if i:
        allowed |= set(dest + "/" + r for r in batches[i - 1])
    for m, p in lines[lo:ei]:
        if m != "status":
            continue
        for path in p.split(","):
            assert path in allowed, (i, path)
PY
  # the record doc carries every file's path, bytes and sha256, all evicted.
  python3 - "$HK_DIR/docs/artifacts_mbp_ds" "$SRC" <<'PY' || return 1
import hashlib, json, os, sys
rec = json.load(open(sys.argv[1]))
src = sys.argv[2]
assert rec["schema"] == "fleet.artifact.v2", rec
arch = rec["archive"]
contents = {c["path"]: c for c in arch["contents"]}
want = {}
for r, ds, fs in os.walk(src):
    for f in fs:
        p = os.path.join(r, f)
        rel = os.path.relpath(p, src)
        want[rel] = (os.path.getsize(p), hashlib.sha256(open(p, "rb").read()).hexdigest())
assert set(contents) == set(want), (set(contents) ^ set(want))
for rel, (sz, sha) in want.items():
    c = contents[rel]
    assert c["bytes"] == sz and c["sha256"] == sha, c
    assert c["evicted"] is True and c["uploaded_at"], c
assert arch["drive_path"].endswith("/mbp/ds"), arch["drive_path"]
assert len(arch["batches"]) == 3, arch["batches"]
for b in arch["batches"]:
    assert b["drive_confirmed_at"] and b["evidence"], b
assert arch["manifest_sha256"] and arch["state"] == "done", arch.get("state")
PY
  # manifest sits next to the dataset with desk's three-column schema.
  assert_file "$DRIVE/mbp/ds.manifest.tsv" || return 1
  python3 - "$DRIVE/mbp/ds.manifest.tsv" "$SRC" <<'PY' || return 1
import hashlib, os, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1])]
assert rows[0] == ["path", "size", "sha256"], rows[0]
body = {r[0]: r for r in rows[1:]}
src = sys.argv[2]
want = {}
for r, ds, fs in os.walk(src):
    for f in fs:
        p = os.path.join(r, f)
        want[os.path.relpath(p, src)] = (os.path.getsize(p), hashlib.sha256(open(p, "rb").read()).hexdigest())
assert set(body) == set(want)
for rel, (sz, sha) in want.items():
    assert body[rel][1] == str(sz) and body[rel][2] == sha, body[rel]
PY
  # the source originals are untouched.
  [[ -f "$SRC/f1.txt" && -f "$SRC/sub/f5.txt" ]] || return 1
}
case_full full || fail "full-path case"
echo "PASS full path two+ batches"

# stuck batch: alert once per run identity, no evict, both runs stop.
case_stuck() {
  reset_case "$1"
  write_hosts_toml 1000000 50
  mk_src a.txt alpha; mk_src b.txt beta
  DEST="$DRIVE/mbp/ds"
  fp_spec a.txt '01'; fp_spec b.txt '01'
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 3 ]] || return 1
  [[ "$(fp_evict_calls)" -eq 0 ]] || return 1
  [[ "$(emit_count)" -eq 1 ]] || return 1
  tr '\0' '\n' <"$PANEWIRE_LOG" | grep -q 'lane.event' || return 1
  tr '\0' '\n' <"$PANEWIRE_LOG" | grep -q 'director-1' || return 1
  tr '\0' '\n' <"$PANEWIRE_LOG" | grep -q 'pending=2' || return 1
  assert_no_file "$DRIVE/mbp/ds.manifest.tsv" || return 1
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 3 ]] || return 1
  [[ "$(emit_count)" -eq 2 ]] || return 1
  python3 - "$PANEWIRE_LOG" <<'PY' || return 1
import sys
args = open(sys.argv[1], "rb").read().split(b"\0")
ids = [args[i + 1].decode() for i, value in enumerate(args[:-1]) if value == b"--event-id"]
assert len(ids) == 2 and len(set(ids)) == 2, ids
PY
}
case_stuck stuck || fail "stuck case"
echo "PASS stuck batch"

# A remote source path stays remote: it must be absolute and must exist and
# be readable on the source host before it can produce an inventory.
case_remote_path_guard() {
  reset_case "$1"
  cat >>"$WRK_HOSTS_CONFIG" <<EOF

[hosts.fh]
ssh = "fakessh"
EOF
  DEST="$DRIVE/mbp/remote-ds"
  run_move relative/tree --dest "$DEST" --source-host fh --apply
  [[ "$MOVE_RC" -eq 2 && ! -s "$SSH_LOG" ]] || return 1
  grep -q 'absolute remote source path' "$ERR" || return 1
  mkdir -p "$TMP/$CASE/rsrc"
  run_move "$TMP/$CASE/missing" --dest "$DEST" --source-host fh --apply
  [[ "$MOVE_RC" -eq 2 ]] || return 1
  grep -q 'missing or not a directory' "$ERR" || return 1
  [[ ! -e "$DEST/remote-ds.manifest.tsv" && ! -s "$HK_DIR/argv.log" ]] || return 1
  run_move "$TMP/$CASE/rsrc" --dest "$DEST" --source-host fh --apply
  [[ "$MOVE_RC" -eq 2 ]] || return 1
  grep -q 'inventory is empty' "$ERR" || return 1
  [[ ! -e "$DEST/remote-ds.manifest.tsv" && ! -s "$HK_DIR/argv.log" ]] || return 1
  chmod 000 "$TMP/$CASE/rsrc"
  run_move "$TMP/$CASE/rsrc" --dest "$DEST" --source-host fh --apply
  chmod 700 "$TMP/$CASE/rsrc"
  [[ "$MOVE_RC" -eq 2 ]] || return 1
  grep -q 'remote source is unreadable' "$ERR" || return 1
}
case_remote_path_guard remote-guards || fail "remote path guard"
echo "PASS remote path, existence and readability guards"

# Empty sources are refused before they can write a manifest or an hk done record.
reset_case empty
DEST="$DRIVE/mbp/empty"
run_move "$SRC" --dest "$DEST" --apply
[[ "$MOVE_RC" -eq 2 ]] || fail "empty: expected rc 2, got $MOVE_RC"
grep -q 'inventory is empty' "$ERR" || fail "empty: refusal should name the empty inventory"
assert_no_file "$DRIVE/mbp/empty.manifest.tsv"
[[ ! -s "$HK_DIR/argv.log" ]] || fail "empty: handoffkeep must not record an empty dataset"
echo "PASS empty inventory refused"

# handoffkeep subprocess failures are a single clean error line with nonzero status.
case_hk_failure() {
  local mode="$1"
  reset_case "hk-$mode"
  mk_src a.txt alpha
  DEST="$DRIVE/mbp/ds"
  fp_spec a.txt 11
  if [[ "$mode" == "missing" ]]; then
    HK="$TMP/$CASE/missing-handoffkeep"
  else
    HK_STUB_MODE="$mode"
    [[ "$mode" == "sleep" ]] && WRK_ARTIFACTS_HK_TIMEOUT_S=0.05
  fi
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 2 ]] || return 1
  [[ "$(wc -l <"$ERR" | tr -d ' ')" -eq 1 ]] || return 1
  ! grep -q 'Traceback' "$ERR" || return 1
  case "$mode" in
    fail) grep -q 'hk record write failed (rc=7): stub failure second line' "$ERR" || return 1 ;;
    missing) grep -q 'hk record write failed: ' "$ERR" || return 1 ;;
    sleep) grep -q 'hk record write timed out' "$ERR" || return 1 ;;
  esac
  unset HK_STUB_MODE WRK_ARTIFACTS_HK_TIMEOUT_S
}
case_hk_failure fail || fail "handoffkeep nonzero failure"
case_hk_failure missing || fail "handoffkeep missing binary"
case_hk_failure sleep || fail "handoffkeep timeout"
echo "PASS handoffkeep failures are clean and nonzero"

# stale DriveFS log -> unknown, never confirmed, never evicted.
case_stale() {
  reset_case "$1"
  write_hosts_toml 1000000 50 10
  mk_src a.txt alpha
  DEST="$DRIVE/mbp/ds"
  fp_spec a.txt 11
  python3 - "$LOGDIR/drive_fs.txt" "$WRK_ARTIFACTS_TIME_FILE" <<'PY'
import os, sys
p, tf = sys.argv[1:3]
t = float(open(tf).read()) - 3600
os.utime(p, (t, t))
PY
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 3 ]] || return 1
  [[ "$(fp_evict_calls)" -eq 0 ]] || return 1
}
case_stale stale || fail "stale-log case"
echo "PASS stale log unknown"

# Drive app not running -> unknown, never confirmed, never evicted.
reset_case appdown
mk_src a.txt alpha
DEST="$DRIVE/mbp/ds"
fp_spec a.txt 11
rm -f "$APPFLAG"
run_move "$SRC" --dest "$DEST" --apply
[[ "$MOVE_RC" -eq 3 ]] || fail "appdown: expected rc 3, got $MOVE_RC"
[[ "$(fp_evict_calls)" -eq 0 ]] || fail "appdown: evict must not run on unknown"
echo "PASS app down unknown"

# uploaded on only one read -> not confirmed.
case_oneread() {
  reset_case "$1"
  write_hosts_toml 1000000 50
  mk_src a.txt alpha
  DEST="$DRIVE/mbp/ds"
  fp_spec a.txt 'seq:11,01'
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 3 ]] || return 1
  [[ "$(fp_evict_calls)" -eq 0 ]] || return 1
}
case_oneread oneread || fail "one-read case"
echo "PASS single read not confirmed"

# evict error: reported, file left in place, never retried in a loop.
reset_case everr
mk_src a.txt alpha
DEST="$DRIVE/mbp/ds"
fp_evict a.txt err
run_move "$SRC" --dest "$DEST" --apply
[[ "$MOVE_RC" -eq 4 ]] || fail "everr: expected rc 4, got $MOVE_RC ($(tail -3 "$ERR"))"
grep -qi 'evict' "$ERR" || fail "everr: evict error must be reported"
assert_file "$DEST/a.txt"
[[ "$(fp_evict_calls)" -eq 1 ]] || fail "everr: evict must not retry in a loop"
python3 - "$HK_DIR/docs/artifacts_mbp_ds" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
row = [c for c in rec["archive"]["contents"] if c["path"] == "a.txt"][0]
assert row["evicted"] is False, row
assert row["uploaded_at"], row
PY
echo "PASS evict error"

# evict ok but the path still reads 11 (evict never took): reported, not evicted.
reset_case evpost
mk_src a.txt alpha
DEST="$DRIVE/mbp/ds"
fp_evict a.txt 'post:11'
run_move "$SRC" --dest "$DEST" --apply
[[ "$MOVE_RC" -eq 4 ]] || fail "evpost: expected rc 4, got $MOVE_RC"
python3 - "$HK_DIR/docs/artifacts_mbp_ds" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
row = [c for c in rec["archive"]["contents"] if c["path"] == "a.txt"][0]
assert row["evicted"] is False, row
PY
echo "PASS evict not-taken"

# ---------------------------------------------------------------------------
# batch limits
# ---------------------------------------------------------------------------

# 2001 files at the default 2000-file cap -> exactly two batches.
reset_case cap2000
write_hosts_toml 100000000 2000
python3 - "$SRC" <<'PY'
import os, sys
for i in range(2001):
    open(os.path.join(sys.argv[1], "f%04d.txt" % i), "w").write("x%d" % i)
PY
DEST="$DRIVE/mbp/ds"
run_move "$SRC" --dest "$DEST" --apply
[[ "$MOVE_RC" -eq 0 ]] || fail "cap2000: rc $MOVE_RC $(tail -3 "$ERR")"
[[ "$(fp_evict_calls)" -eq 2 ]] || fail "cap2000: expected 2 evict calls, got $(fp_evict_calls)"
fp_calls | grep '^evict' | python3 -c '
import sys
lines = [l.rstrip("\n").split("\t")[1].split(",") for l in sys.stdin]
assert len(lines) == 2 and len(lines[0]) == 2000 and len(lines[1]) == 1, [len(l) for l in lines]
'
echo "PASS 2001 files -> 2 batches"

# one file larger than the batch byte cap forms a batch by itself.
reset_case bigfile
write_hosts_toml 1000 50
head -c 1500 /dev/zero >"$SRC/big.bin"
mk_src small.txt s
DEST="$DRIVE/mbp/ds"
run_move "$SRC" --dest "$DEST" --apply
[[ "$MOVE_RC" -eq 0 ]] || fail "bigfile: rc $MOVE_RC $(tail -3 "$ERR")"
fp_calls | grep '^evict' | python3 -c '
import sys
lines = [l.rstrip("\n").split("\t")[1].split(",") for l in sys.stdin]
big = [l for l in lines if any(p.endswith("big.bin") for p in l)]
assert len(big) == 1 and len(big[0]) == 1, "big file not alone in its batch: %s" % lines
'
echo "PASS oversized file alone in batch"

# ---------------------------------------------------------------------------
# exclusions
# ---------------------------------------------------------------------------

case_excl() {
  reset_case "$1"
  mk_src keep.txt keep
  mk_src .env secret1; mk_src x.env secret2; mk_src .env.local secret3
  mk_src auth.json secret4; mk_src x_token.txt secret5; mk_src mysecret.md secret6
  mk_src Cookies secret7; mk_src "Login Data" secret8; mk_src .DS_Store secret9
  mk_src sub/.env nested; mk_src sub/ok.txt ok
  DEST="$DRIVE/mbp/ds"
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 0 ]] || return 1
  local n
  for n in .env x.env .env.local auth.json x_token.txt mysecret.md Cookies "Login Data" .DS_Store; do
    [[ ! -e "$DEST/$n" ]] || return 1
  done
  [[ ! -e "$DEST/sub/.env" ]] || return 1
  [[ -f "$DEST/keep.txt" && -f "$DEST/sub/ok.txt" ]] || return 1
  # excluded names appear nowhere in the record, manifest or state file.
  python3 - "$HK_DIR/docs/artifacts_mbp_ds" "$DRIVE/mbp/ds.manifest.tsv" "$STATEDIR/ds.state.json" <<'PY' || return 1
import sys
rec = open(sys.argv[1]).read()
man = open(sys.argv[2]).read()
st = open(sys.argv[3]).read()
bad = [".env", "auth.json", "token", "secret", "Cookies", "Login Data", ".DS_Store"]
for b in bad:
    assert b not in rec, (b, rec)
    assert b not in man, (b, man)
    assert b not in st, (b, st)
PY
}
case_excl excl || fail "exclusions case"
echo "PASS exclusions"

# ---------------------------------------------------------------------------
# state-file skip rule
# ---------------------------------------------------------------------------

# matching state sha -> skipped (never re-confirmed, never re-evicted);
# same size but different sha -> copied again.
case_stateskip() {
  reset_case "$1"
  write_hosts_toml 1000000 50
  mk_src same.txt stable
  mk_src changed.txt newcontent-here
  DEST="$DRIVE/mbp/ds"
  mkdir -p "$DEST"
  printf '%s\n' 'DIFFERENT bytes same length' >"$DEST/same.txt"
  printf '%s\n' 'DIFFERENT bytes same length!' >"$DEST/changed.txt"
  python3 - "$STATEDIR/ds.state.json" "$SRC" <<'PY'
import hashlib, json, sys
st_path, src = sys.argv[1:3]
def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()
st = {
  "same.txt": {"size": len("stable") + 1, "sha256": sha(src + "/same.txt"), "confirmed": True},
  "changed.txt": {"size": len("newcontent-here") + 1, "sha256": "0" * 64, "confirmed": True},
}
json.dump(st, open(st_path, "w"))
PY
  run_move "$SRC" --dest "$DEST" --apply
  [[ "$MOVE_RC" -eq 0 ]] || return 1
  python3 - "$FPBULK_DIR/calls.log" "$DEST" <<'PY' || return 1
import os, sys
joined = open(sys.argv[1]).read() if os.path.exists(sys.argv[1]) else ""
assert "same.txt" not in joined, "state-matched file must not be copied/confirmed: %s" % joined
assert "changed.txt" in joined, "sha-mismatch file must be copied again: %s" % joined
PY
  python3 - "$HK_DIR/docs/artifacts_mbp_ds" "$SRC" <<'PY' || return 1
import hashlib, json, sys
rec = json.load(open(sys.argv[1]))
contents = {c["path"]: c for c in rec["archive"]["contents"]}
assert contents["same.txt"]["evicted"] is True
new_sha = hashlib.sha256(open(sys.argv[2] + "/changed.txt", "rb").read()).hexdigest()
assert contents["changed.txt"]["sha256"] == new_sha, contents["changed.txt"]
PY
}
case_stateskip stateskip || fail "state-skip case"
echo "PASS state-file skip rule"

# ---------------------------------------------------------------------------
# a source file that changes mid-run is skipped and reported
# ---------------------------------------------------------------------------

reset_case churn
write_hosts_toml 1000000 1
mk_src a.txt alpha; mk_src b.txt beta
DEST="$DRIVE/mbp/ds"
# batch 0's first status call mutates b.txt (still pending in a later batch).
printf 'printf "mutated during run\\n" >>"%s/b.txt"\n' "$SRC" >"$FPBULK_DIR/on_status"
chmod +x "$FPBULK_DIR/on_status"
run_move "$SRC" --dest "$DEST" --apply
[[ "$MOVE_RC" -eq 4 ]] || fail "churn: expected rc 4, got $MOVE_RC ($(tail -3 "$ERR"))"
grep -qi 'chang' "$ERR" || fail "churn: mid-run change must be reported"
assert_no_file "$DEST/b.txt"
python3 - "$HK_DIR/docs/artifacts_mbp_ds" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
paths = [c["path"] for c in rec["archive"]["contents"]]
assert "b.txt" not in paths, paths
PY
echo "PASS mid-run change skipped"

# ---------------------------------------------------------------------------
# remote source
# ---------------------------------------------------------------------------

reset_case remote
write_hosts_toml 1000000 2
cat >>"$WRK_HOSTS_CONFIG" <<EOF

[hosts.fh]
ssh = "fakessh"
EOF
RSRC="$TMP/$CASE/rsrc"; mkdir -p "$RSRC/sub"
printf 'r1\n' >"$RSRC/r1.txt"; printf 'r2\n' >"$RSRC/sub/r2.txt"; printf 'r3\n' >"$RSRC/r3.txt"
printf 'never\n' >"$RSRC/x_token.txt"
before_sig="$(tree_sig "$RSRC")"
DEST="$DRIVE/mbp/remote-ds"
WRK_ARTIFACTS_FREE_BYTES=999999999999 run_move "$RSRC" --dest "$DEST" --apply --source-host fh
[[ "$MOVE_RC" -eq 0 ]] || fail "remote: rc $MOVE_RC $(tail -3 "$ERR")"
[[ -s "$SSH_LOG" ]] || fail "remote: ssh inventory never ran"
[[ -s "$RSYNC_LOG" ]] || fail "remote: rsync never ran"
tr '\0' '\n' <"$RSYNC_LOG" | grep -q -- '--files-from' || fail "remote: rsync must pull a file list"
! tr '\0' '\n' <"$RSYNC_LOG" | grep -q -- '--delete' || fail "remote: rsync must never see --delete"
[[ "$(emit_count)" -eq 0 ]] || fail "remote: no alert expected"
assert_file "$DEST/r1.txt"; assert_file "$DEST/sub/r2.txt"; assert_file "$DEST/r3.txt"
assert_no_file "$DEST/x_token.txt"
# scratch deleted after the batch evicted; remote tree untouched.
[[ -z "$(find "$SCRATCH" -type f 2>/dev/null)" ]] || fail "remote: scratch copy must be deleted after evict"
[[ "$(tree_sig "$RSRC")" == "$before_sig" ]] || fail "remote: the remote original must never be modified"
python3 - "$HK_DIR/docs/artifacts_mbp_remote-ds" <<'PY'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["schema"] == "fleet.artifact.v2"
contents = {c["path"] for c in rec["archive"]["contents"]}
assert contents == {"r1.txt", "sub/r2.txt", "r3.txt"}, contents
assert all(c["evicted"] for c in rec["archive"]["contents"])
PY
echo "PASS remote source"

# low free space: the batch pull is skipped with the reason, nothing moves.
reset_case lowspace
cat >>"$WRK_HOSTS_CONFIG" <<EOF

[hosts.fh]
ssh = "fakessh"
EOF
RSRC="$TMP/$CASE/rsrc"; mkdir -p "$RSRC"
printf 'r1\n' >"$RSRC/r1.txt"
DEST="$DRIVE/mbp/remote-ds"
WRK_ARTIFACTS_FREE_BYTES=1 run_move "$RSRC" --dest "$DEST" --apply --source-host fh
[[ "$MOVE_RC" -eq 4 ]] || fail "lowspace: expected rc 4, got $MOVE_RC ($(tail -3 "$ERR"))"
grep -qi 'space\|free' "$ERR" || fail "lowspace: refusal must carry the free-space reason"
assert_no_file "$DEST/r1.txt"
[[ ! -s "$RSYNC_LOG" ]] || fail "lowspace: rsync must not run when space is short"
echo "PASS low free space"

# remote sha256 checked after pull: a corrupted pull is skipped, not moved.
reset_case corrupt
cat >>"$WRK_HOSTS_CONFIG" <<EOF

[hosts.fh]
ssh = "fakessh"
EOF
RSRC="$TMP/$CASE/rsrc"; mkdir -p "$RSRC"
printf 'good\n' >"$RSRC/g.txt"
DEST="$DRIVE/mbp/remote-ds"
# rsync stub variant that flips a byte mid-pull.
cat >"$RSYNC" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "$@" >>"$RSYNC_LOG"; printf '\0' >>"$RSYNC_LOG"
args=("$@")
dst="${args[$(($#-1))]}"
src=""
for a in "$@"; do [[ "$a" == *:* && "$a" != -* ]] && src="${a#*:}"; done
src="${src%/}"
listfile="$(mktemp)"
cat >"$listfile"
python3 - "$src" "$dst" "$listfile" <<'PY'
import os, sys
src, dst, listfile = sys.argv[1:4]
data = open(listfile, "rb").read()
for rel in [p.decode() for p in data.split(b"\0") if p]:
    s, d = os.path.join(src, rel), os.path.join(dst, rel)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    open(d, "wb").write(open(s, "rb").read() + b"corrupt")
PY
rm -f "$listfile"
SH
chmod +x "$RSYNC"
WRK_ARTIFACTS_FREE_BYTES=999999999999 run_move "$RSRC" --dest "$DEST" --apply --source-host fh
[[ "$MOVE_RC" -eq 4 ]] || fail "corrupt: expected rc 4, got $MOVE_RC ($(tail -3 "$ERR"))"
grep -qi 'sha\|hash\|mismatch' "$ERR" || fail "corrupt: sha mismatch must be reported"
assert_no_file "$DEST/g.txt"
[[ "$(fp_evict_calls)" -eq 0 ]] || fail "corrupt: a corrupt pull must not be confirmed or evicted"
echo "PASS corrupt pull skipped"

# ---------------------------------------------------------------------------
# mutants: a targeted mutation of bin/wrk must make the named case fail (RED).
# ---------------------------------------------------------------------------

echo "== MUT: assertion-RED mutants =="

MUT="$TMP/mutants"; mkdir -p "$MUT"

mkmut() { # NAME SED-EXPR — build a mutated wrk copy
  local mut="$MUT/wrk-$1"
  if ! { sed "$2" "$WRK" >"$mut" && chmod +x "$mut"; }; then
    fail "mutant build failed: $2"
  fi
  MUT_WRK="$mut"
}

expect_mut_red() { # DESC CASE_FN CASE_NAME
  local desc="$1" fn="$2" name="$3"
  local saved="$WRK"; WRK="$MUT_WRK"
  if "$fn" "$name"; then
    WRK="$saved"
    fail "MUT $desc: mutant stayed GREEN — the check is decorative"
  fi
  WRK="$saved"
  echo "PASS mut $desc is assertion-RED"
}

# Absolutizing SRC_TREE on the local host or accepting a missing remote root
# must make the new remote guard case go RED at the real call site.
mkmut remote-local-abspath 's/if source_host is None:/if True:/'
expect_mut_red "remote source is absolutized locally" case_remote_path_guard mut-remote-local-abspath

mkmut remote-missing-root 's/if not os.path.isdir(src): raise SystemExit/if not True: raise SystemExit/'
expect_mut_red "remote missing directory accepted" case_remote_path_guard mut-remote-missing-root

# evict without requiring every file confirmed -> stuck case goes RED.
mkmut evict-unconfirmed 's/all(s == "confirmed" for s, _ in states.values())/True/'
expect_mut_red "evict before batch confirmed" case_stuck mut-stuck

# drop the freshness guard -> the stale-log case goes RED.
mkmut no-freshness 's/bool(log_mtimes) and now_s - max(log_mtimes) <= stale_s/True/'
expect_mut_red "freshness guard removal" case_stale mut-stale

# accept a single read -> the single-read case goes RED.
mkmut one-read 's/first_ok is not None and now() - first_ok >= CONFIRM_GAP_S/True/'
expect_mut_red "single-read acceptance" case_oneread mut-oneread

# skip by size only (ignore the state-file sha256) -> the changed-sha case goes RED.
mkmut skip-size-only 's/rec.get("sha256") == cur_sha/True/'
expect_mut_red "size-only state skip" case_stateskip mut-stateskip

# drop the exclusion application -> the exclusions case goes RED.
mkmut no-exclusions 's/if excluded(f):/if False:/'
expect_mut_red "exclusion removal" case_excl mut-excl

echo "PASS test-wrk-artifacts-move: all cases"
