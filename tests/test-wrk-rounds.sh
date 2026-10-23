#!/usr/bin/env bash
# hk 1449: exercise real CLI call sites against temporary jobs and inert tools.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop(1))
WRK = ROOT / "bin/wrk"


class Rounds(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sandbox = tempfile.TemporaryDirectory(prefix="wr1449-", dir="/tmp")
        cls.base = Path(cls.sandbox.name)
        cls.repo = cls.base / "repo"
        cls.repo.mkdir()
        cls.git_env = {"PATH": os.environ["PATH"], "HOME": str(cls.base),
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        def git(*args):
            return subprocess.check_output(["git", "-C", str(cls.repo), *args],
                                           env=cls.git_env, stderr=subprocess.DEVNULL, text=True).strip()
        git("init", "-q")
        git("config", "user.name", "Round fixture")
        git("config", "user.email", "round@example.invalid")
        cls.heads = []
        for n in range(5):
            (cls.repo / "file").write_text(str(n))
            git("add", "file")
            git("commit", "-qm", "fixture commit " + str(n))
            cls.heads.append(git("rev-parse", "HEAD"))

    @classmethod
    def tearDownClass(cls):
        cls.sandbox.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="case-", dir=self.base)
        self.addCleanup(self.tmp.cleanup)
        self.case = Path(self.tmp.name)
        self.jobs = self.case / "jobs"
        self.jobs.mkdir()
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.case / "home"),
                    "CODEX_HOME": str(self.case / "codex"), "TMPDIR": str(self.base / "tmp"),
                    "ARBITER_INBOX_ROOT": str(self.jobs), "WRK_NO_SLEEP": "1",
                    "WRK_JOB_DELEGATE": "0", "ARBITER_BIN": str(self.case / "absent"),
                    "PANEWIRE_BIN": str(self.case / "panewire"),
                    "HANDOFFKEEP_BIN": str(self.case / "hk"),
                    "HERDR_BIN": str(ROOT / "tests/fixtures/herdr"),
                    "SCOPEFUEL_BIN": str(ROOT / "tests/fixtures/scopefuel"),
                    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        for key in ("CONFIG", "CACHE", "DATA", "STATE", "RUNTIME"):
            self.env["XDG_RUNTIME_DIR" if key == "RUNTIME" else "XDG_" + key + "_HOME"] = str(self.case / key)
        for key in ("HOME", "CODEX_HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                    "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"):
            Path(self.env[key]).mkdir(exist_ok=True)
        self.stub("panewire", "raise SystemExit(0)")
        self.stub("hk", '''import json, sys
if sys.argv[1:3] == ["doc", "get"]:
    job, kind, number = sys.argv[3].split(":")
    grant = "round-void: job=%s round=%s by=director-1" % (job, number) if kind == "void" else "round-extension: job=%s extra=%s by=director-1" % (job, number)
    print(json.dumps({"created_by": "director-1", "body": grant}))
''')
        self.report = self.case / "report.md"
        self.report.write_text("DONE fixture\n")
        self.wrk = WRK

    def stub(self, name, body):
        path = self.case / name
        path.write_text("#!/usr/bin/env python3\n" + body + "\n")
        path.chmod(0o700)
        return path

    def event(self, job, kind, **fields):
        events = self.jobs / job / "events"
        events.mkdir(parents=True, exist_ok=True)
        n = max([int(p.name.split("-")[0]) for p in events.glob("*.json")] or [0]) + 1
        path = events / ("%05d-%s.json" % (n, kind))
        path.write_text(json.dumps({"kind": kind, "job_id": job, **fields}))
        return path

    def job(self, job="builder", parent="director-1", role="builder"):
        self.event(job, "job.claim", payload={"owner_lane": job + "-lane", "label": job,
                   "pane_id": "w:p1", "parent_lane": parent, "role": role, "repo": str(self.repo)})
        return job

    def run_wrk(self, *args, ok=True):
        result = subprocess.run(["bash", str(self.wrk), *map(str, args)], env=self.env,
                                capture_output=True, text=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def records(self, job, kind):
        return [json.loads(p.read_text()) for p in sorted((self.jobs / job / "events").glob("*.json"))
                if json.loads(p.read_text()).get("kind") == kind]

    def snapshot(self):
        # Includes directories, files, bytes and mtimes: audit must not even touch a lock.
        return [(str(p.relative_to(self.jobs)), p.lstat().st_mtime_ns,
                 p.read_bytes() if p.is_file() else None)
                for p in sorted(self.jobs.rglob("*"))]

    def verdict(self, job, head=0, name="verdict.md", body="findings\n"):
        path = self.jobs / job / name
        path.write_text("VERDICT: PASS @" + self.heads[head] + "\n" + body)
        return path

    def open(self, job, head=0, *extra):
        return self.run_wrk("round", "open", job, "--head", self.heads[head], *extra)

    def record(self, job, path):
        return self.run_wrk("round", "verdict", job, "--file", path)

    def join(self, job, *extra, ok=True):
        return self.run_wrk("joined", job, "--pr", "https://example.invalid/pr/1",
                            "--head", self.heads[0], "--report", self.report, *extra, ok=ok)

    def refused(self, job, args, needle):
        before = self.snapshot()
        result = self.run_wrk(*args, ok=False)
        self.assertNotEqual(result.returncode, 0, "must refuse: " + " ".join(map(str, args)))
        self.assertIn(needle, result.stderr)
        self.assertEqual(len(result.stderr.splitlines()), 1, result.stderr)
        # A refusal must not append any event (lock metadata is not an event).
        after = self.snapshot()
        self.assertEqual([r for r in before if r[0].endswith(".json")],
                         [r for r in after if r[0].endswith(".json")])
        return result

    def test_same_path(self):
        job = self.job()
        path = self.verdict(job)
        self.record(job, path)
        earlier = next((self.jobs / job / "events").glob("*-job.verdict.json"))
        self.refused(job, ["round", "verdict", job, "--file", path], earlier.name)
        path.write_text("VERDICT: PASS @" + self.heads[1] + "\nchanged\n")
        self.refused(job, ["round", "verdict", job, "--file", path], earlier.name)

    def test_same_content_new_path(self):
        job = self.job()
        path = self.verdict(job)
        self.open(job)
        self.record(job, path)
        recorded = self.records(job, "job.verdict")[0]
        self.assertEqual(recorded.get("sha256"), hashlib.sha256(path.read_bytes()).hexdigest())
        copy = self.jobs / job / "copy.md"
        copy.write_bytes(path.read_bytes())
        # A different head on the old record isolates the content check from head dedup.
        old = next((self.jobs / job / "events").glob("*-job.verdict.json"))
        data = json.loads(old.read_text()); data["head"] = self.heads[1]
        old.write_text(json.dumps(data))
        self.refused(job, ["round", "verdict", job, "--file", copy], old.name)

    def test_same_head_and_void_exception(self):
        job = self.job()
        self.open(job)
        self.record(job, self.verdict(job))
        second = self.verdict(job, name="second.md", body="different\n")
        old = next((self.jobs / job / "events").glob("*-job.verdict.json"))
        self.refused(job, ["round", "verdict", job, "--file", second], old.name)
        # Historical imported voids can coexist with verdicts; the void command still
        # refuses to void an already-verdict-bearing round, as before hk 1449.
        self.event(job, "job.round_void", round=1, ref="hk:task/1")
        self.record(job, second)

    def test_end_reclaim(self):
        for command in ("open", "verdict", "void", "joined"):
            for end in ("job.revoked", "job.reaped", "job.handed_off"):
                with self.subTest(command=command, end=end):
                    job = self.job(command + end.replace(".", ""))
                    self.open(job)
                    path = self.verdict(job)
                    if command == "joined":
                        self.record(job, path)
                    ended = self.event(job, end)
                    args = {"open": ["round", "open", job, "--head", self.heads[1]],
                            "verdict": ["round", "verdict", job, "--file", path],
                            "void": ["round", "void", job, "1", "--by", "hk:doc/" + job + ":void:1"],
                            "joined": ["joined", job, "--pr", "url", "--head", self.heads[0], "--report", self.report]}
                    self.refused(job, args[command], ended.name)
                    meta = self.records(job, "job.claim")[0]["payload"]
                    self.event(job, "job.reclaim", payload=meta)
                    self.run_wrk(*args[command])

    def test_same_second_end_order(self):
        job = self.job()
        self.open(job)
        ended = self.event(job, "job.revoked", at="2026-10-23T01:00:00.999Z")
        revived = self.event(job, "job.reclaim", at="2026-10-23T01:00:00Z",
                             payload=self.records(job, "job.claim")[0]["payload"])
        # Use a future second for both compared records, after the fixture open.
        for path in (ended, revived):
            data = json.loads(path.read_text()); data["at"] = data["at"].replace("2026-10-23", "2099-10-23")
            path.write_text(json.dumps(data))
        os.utime(ended, (100, 100)); os.utime(revived, (101, 101))
        self.open(job, 1)
        os.utime(ended, (102, 102))
        self.refused(job, ["round", "open", job, "--head", self.heads[2]], ended.name)

    def test_zero_rounds_and_waiver(self):
        job = self.job()
        self.refused(job, ["joined", job, "--pr", "url", "--head", self.heads[0], "--report", self.report], "zero non-voided recorded rounds")
        self.join(job, "--rounds-waived", "hk:task/1")
        self.assertEqual(self.records(job, "job.joined")[0].get("rounds_waived"), "hk:task/1")

    def test_unmatched_and_matched(self):
        job = self.job()
        self.open(job)
        path = self.verdict(job)
        self.refused(job, ["joined", job, "--pr", "url", "--head", self.heads[0], "--report", self.report], str(path))
        self.record(job, path)
        # A renamed file matches by hash, even after the original path disappears.
        path.rename(path.with_name("renamed.md"))
        self.join(job)

    def test_unmatched_waiver_and_bad_ref(self):
        job = self.job()
        self.open(job)
        self.verdict(job)
        for ref in ("task/1", "hk:task/", "hk:doc/", "hk:task/not-an-id"):
            self.assertNotEqual(self.join(job, "--rounds-waived", ref, ok=False).returncode, 0)
        self.join(job, "--rounds-waived", "hk:doc/approved")
        self.assertEqual(self.records(job, "job.joined")[0]["rounds_waived"], "hk:doc/approved")

    def test_done_warning(self):
        job = self.job()
        self.verdict(job)
        result = self.run_wrk("done", job, "--report", self.report)
        warnings = [line for line in result.stderr.splitlines() if "ROUND RECORD WARNING" in line]
        self.assertEqual(len(warnings), 1, result.stderr)
        self.assertIn("zero non-voided recorded rounds", warnings[0])
        self.assertIn("verdict.md", warnings[0])
        worker = self.job("worker", role="worker")
        self.assertNotIn("ROUND RECORD WARNING", self.run_wrk("done", worker, "--report", self.report).stderr)

    def test_normal_rounds_join(self):
        for rounds in (1, 2, 3):
            job = self.job("normal" + str(rounds))
            for n in range(rounds):
                self.open(job, n)
                self.record(job, self.verdict(job, n, "v%d.md" % n))
            self.join(job)
            self.assertEqual(len(self.records(job, "job.joined")), 1)

    def test_voided_round_join(self):
        job = self.job()
        self.open(job)
        self.run_wrk("round", "void", job, "1", "--by", "hk:doc/" + job + ":void:1")
        self.refused(job, ["joined", job, "--pr", "url", "--head", self.heads[0], "--report", self.report], "zero non-voided recorded rounds")
        self.open(job, 1)
        self.record(job, self.verdict(job, 1))
        self.join(job)

    def test_takeover_inherited_join(self):
        job = self.job()
        self.event(job, "job.takeover", payload={"rounds_used": 2})
        self.assertIn("rounds=2", self.run_wrk("round", "status", job).stdout)
        self.join(job)

    def test_extended_round_join(self):
        job = self.job()
        for n in range(3):
            self.open(job, n)
            self.record(job, self.verdict(job, n, "v%d.md" % n))
        self.open(job, 3, "--extend", "hk:doc/" + job + ":extend:1")
        self.record(job, self.verdict(job, 3, "v3.md"))
        self.join(job)

    def delegate(self, rc):
        self.env["WRK_JOB_DELEGATE"] = "1"
        self.stub("panewire", '''import json, os, pathlib, sys
if sys.argv[1:3] == ["job", "probe"]: print("panewire-job/1")
elif sys.argv[1:3] == ["job", "joined"]:
    events = pathlib.Path(os.environ["ARBITER_INBOX_ROOT"]) / sys.argv[3] / "events"
    n = max(int(p.name.split("-")[0]) for p in events.glob("*.json")) + 1
    (events / ("%05d-job.joined.json" % n)).write_text(json.dumps({"kind": "job.joined", "job_id": sys.argv[3]}))
    (events.parent / "delegated").write_text("yes")
    raise SystemExit(''' + str(rc) + ''')
''')

    def test_delegated_join(self):
        self.delegate(0)
        job = self.job()
        self.open(job)
        self.join(job)
        self.assertTrue((self.jobs / job / "delegated").exists())
        self.assertEqual(len(self.records(job, "job.revoked")), 1, "delegated housekeeping must run")

    def test_partial_delegate_join(self):
        self.delegate(1)
        job = self.job()
        self.open(job)
        self.assertIn("suppressed duplicate", self.join(job).stderr)
        self.assertEqual(len(self.records(job, "job.joined")), 1)
        self.assertEqual(len(self.records(job, "job.revoked")), 1)

    def test_delegate_cannot_bypass_guard(self):
        self.delegate(0)
        job = self.job()
        self.assertNotEqual(self.join(job, ok=False).returncode, 0)
        self.assertFalse((self.jobs / job / "delegated").exists())
        self.join(job, "--rounds-waived", "hk:task/1")
        self.assertEqual(self.records(job, "job.joined")[0]["rounds_waived"], "hk:task/1")

    def test_parking_arcade_join(self):
        job = self.job(parent="pa-integrator")
        self.open(job)
        self.record(job, self.verdict(job))
        self.join(job)
        self.assertEqual(self.records(job, "job.joined")[0]["parent_lane"], "pa-integrator")

    def test_unopened_verdict_join_and_binding_unchanged(self):
        job = self.job()
        self.record(job, self.verdict(job))
        self.join(job)
        job = self.job("binding")
        self.open(job, 0)
        self.open(job, 1)
        self.record(job, self.verdict(job, 1))
        self.assertEqual(self.records(job, "job.verdict")[0]["round"], 1, "hk 1506 binding target must stay unchanged")
        job = self.job("completed-bookkeeping")
        self.event(job, "job.completed")
        self.open(job)
        self.record(job, self.verdict(job))
        self.join(job)

    def test_file_scope_and_byte_hash(self):
        job = self.job()
        self.open(job)
        path = self.verdict(job)
        self.record(job, path)
        (self.jobs / job / "sub").mkdir()
        self.verdict(job, 1, "sub/unrecorded.md")
        (self.jobs / job / "symlink.md").symlink_to(self.verdict(job, 1, "sub/target.md"))
        # Direct regular files only; neither nested files nor symlinks are audit inputs.
        self.join(job)
        job = self.job("bytes")
        self.open(job)
        path = self.verdict(job)
        self.record(job, path)
        variant = self.jobs / job / "variant.md"
        for content in (path.read_bytes().replace(b"\n", b"\r\n"), path.read_bytes() + b" \n"):
            variant.write_bytes(content)
            # Raw content differs, but head dedup still prevents this dodge.
            self.assertNotEqual(self.run_wrk("round", "verdict", job, "--file", variant, ok=False).returncode, 0)

    def test_audit_read_only(self):
        self.job("zero")
        self.job("worker", role="worker")
        self.job("ended"); self.event("ended", "job.revoked")
        self.job("completed"); self.event("completed", "job.completed")
        self.job("matched"); self.record("matched", self.verdict("matched"))
        self.job("unmatched"); self.open("unmatched"); path = self.verdict("unmatched")
        second = self.verdict("unmatched", 1, "verdict2.md")
        self.job("both"); self.verdict("both")
        self.job("ended-file"); self.event("ended-file", "job.revoked"); self.verdict("ended-file")
        self.job("voided"); self.open("voided")
        self.run_wrk("round", "void", "voided", "1", "--by", "hk:doc/voided:void:1")
        self.job("inherited"); self.event("inherited", "job.takeover", payload={"rounds_used": 1})
        before = self.snapshot()
        result = self.run_wrk("round", "audit")
        lines = result.stdout.splitlines()
        self.assertEqual(set(lines), {"job=zero zero non-voided recorded rounds",
            "job=both zero non-voided recorded rounds", "job=voided zero non-voided recorded rounds",
            "job=unmatched unmatched verdict file: " + str(path) + "; " + str(second),
            "job=both unmatched verdict file: " + str(self.jobs / "both/verdict.md"),
            "job=ended-file unmatched verdict file: " + str(self.jobs / "ended-file/verdict.md")})
        self.assertEqual(len(lines), 6)
        self.assertEqual(self.snapshot(), before, "audit changed the before/after job directory listing")
        self.assertEqual(self.run_wrk("round", "audit", "--lane", "zero-lane").stdout,
                         "job=zero zero non-voided recorded rounds\n")
        self.assertEqual(self.snapshot(), before)

    def test_call_site_mutants(self):
        source = WRK.read_text()
        mutations = [
            ("content-hash", 'if previous.get("sha256") == digest:', 'if False:', "test_same_content_new_path"),
            ("joined-end", '  round_require_live "$job" "joined"', '  : removed joined end check', "test_end_reclaim"),
            ("voided-count", 'used = wrk_round_used(events)', 'used = len([o for _, o, _ in wrk_events_ordered(events) if o and o.get("kind") == "job.round"]) + wrk_takeover_rounds(events)', "test_voided_round_join"),
        ]
        if 'def wrk_round_used(' not in source:
            self.skipTest("pre-implementation RED run")
        for name, old, new, case in mutations:
            with self.subTest(invariant=name):
                self.assertIn(old, source, "mutant must alter the real call site")
                mutant = self.case / ("wrk-" + name)
                mutant.write_text(source.replace(old, new))
                # Reuse exactly the same consumer assertion with a substituted real CLI.
                trial = Rounds(case)
                trial.setUp()
                trial.wrk = mutant
                try:
                    with self.assertRaises(AssertionError, msg="surviving mutant: " + name):
                        getattr(trial, case)()
                finally:
                    trial.doCleanups()


unittest.main(verbosity=2)
PY
