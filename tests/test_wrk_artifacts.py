#!/usr/bin/env python3
"""hk 2093 artifact classifier and final-mark contract; every tree is temporary."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
WRK = ROOT / "bin/wrk"


class ArtifactsContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="wrk-artifacts-")
        self.base = Path(self.tmp.name)
        self.work = self.base / "work"
        self.jobs = self.work / "herdr-inbox/jobs"
        self.flat = self.work / "flat-root"
        self.jobs.mkdir(parents=True)
        self.flat.mkdir(parents=True)
        for part in ("home", "xdg/config", "xdg/data", "xdg/cache", "xdg/state", "codex"):
            (self.base / part).mkdir(parents=True)
        self.policy_path = self.base / "policy.json"
        self.policy = {
            "schema": "fleet.artifact-policy.v1",
            "roots": {
                "jobs": "herdr-inbox/jobs",
                "flat": {"path": "flat-root", "kind": "flat"},
            },
            "rows": [],
        }
        self.write_policy()

    def tearDown(self):
        self.tmp.cleanup()

    def write_policy(self):
        self.policy_path.write_text(json.dumps(self.policy), encoding="utf-8")

    def env(self, host="m1"):
        return {
            "PATH": os.defpath,
            "HOME": str(self.base / "home"),
            "XDG_CONFIG_HOME": str(self.base / "xdg/config"),
            "XDG_DATA_HOME": str(self.base / "xdg/data"),
            "XDG_CACHE_HOME": str(self.base / "xdg/cache"),
            "XDG_STATE_HOME": str(self.base / "xdg/state"),
            "CODEX_HOME": str(self.base / "codex"),
            "TMPDIR": str(self.base),
            "ARBITER_INBOX_ROOT": str(self.jobs),
            "WRK_ARTIFACT_POLICY": str(self.policy_path),
            "WRK_ARTIFACT_HOST": host,
            "WRK_TEST_MODE": "1",
            "HERDR_BIN": str(ROOT / "tests/fixtures/herdr"),
            "SCOPEFUEL_BIN": str(ROOT / "tests/fixtures/scopefuel"),
            "ARBITER_BIN": str(ROOT / "bin/arbiter"),
            "HANDOFFKEEP_BIN": str(ROOT / "tests/fixtures/handoffkeep"),
        }

    def run_wrk(self, *args, binary=WRK, host="m1"):
        return subprocess.run([str(binary), *args], cwd=ROOT, env=self.env(host),
                              text=True, capture_output=True)

    def row(self, cls, root="jobs", glob="*.bin", **kw):
        value = {"class": cls, "root": root, "glob": glob}
        value.update(kw)
        return value

    def test_classify_bytes_paths_and_heavy_unclassified(self):
        job = self.jobs / "j1"
        (job / "evidence").mkdir(parents=True)
        evidence = job / "evidence/shot.bin"
        evidence.write_bytes(b"capture-data")
        guarded = job / "refs/kept.bin"
        guarded.parent.mkdir(); guarded.write_bytes(b"protected-record")
        heavy = job / "unknown/sixty-mb.bin"
        heavy.parent.mkdir()
        with heavy.open("wb") as handle:
            handle.truncate(60 * 1024 * 1024)
        self.policy["rows"] = [self.row("evidence", glob="evidence/*.bin", mirror_required=True),
                                self.row("protected", glob="refs/**")]
        self.write_policy()
        result = self.run_wrk("artifacts", "classify", "--job", "j1", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)["jobs"]["j1"]
        self.assertEqual(report["classes"]["evidence"]["bytes"], len(b"capture-data"))
        self.assertEqual(report["classes"]["evidence"]["paths"][0]["path"], str(evidence))
        self.assertIn(str(evidence), report["mirror_required"])
        self.assertEqual(report["classes"]["protected"]["bytes"], len(b"protected-record"))
        self.assertIn(str(guarded), report["never_touch"])
        self.assertIn({"path": str(heavy), "bytes": 60 * 1024 * 1024}, report["unclassified"])

    def test_host_filtering_flat_root_and_job_key(self):
        (self.flat / "one.bin").write_bytes(b"flat")
        (self.jobs / "j1").mkdir()
        (self.jobs / "j2").mkdir()
        (self.jobs / "j1/only.bin").write_bytes(b"one")
        (self.jobs / "j2/only.bin").write_bytes(b"two")
        self.policy["rows"] = [
            self.row("evidence", "flat", "*.bin", host="m1"),
            self.row("record-text", "jobs", "only.bin", job="j1"),
        ]
        self.write_policy()
        skipped = self.run_wrk("artifacts", "classify", "--root", "flat", "--json", host="m2")
        skipped_jobs = json.loads(skipped.stdout)["jobs"]
        self.assertTrue(not skipped_jobs or skipped_jobs.get("root:flat", {}).get("classes", {}) == {})
        applied = self.run_wrk("artifacts", "classify", "--root", "flat", "--json", host="m1")
        self.assertEqual(json.loads(applied.stdout)["jobs"]["root:flat"]["classes"]["evidence"]["bytes"], 4)
        only_j1 = self.run_wrk("artifacts", "classify", "--job", "j1", "--json")
        only_j2 = self.run_wrk("artifacts", "classify", "--job", "j2", "--json")
        self.assertIn("record-text", json.loads(only_j1.stdout)["jobs"]["j1"]["classes"])
        self.assertNotIn("record-text", json.loads(only_j2.stdout)["jobs"]["j2"]["classes"])

    def test_webqa_sha_dirs_fail_closed_as_protected(self):
        build = self.work / "webqa-runner/v3/builds/abcdef123"
        build.mkdir(parents=True)
        payload = build / "app.bin"; payload.write_bytes(b"sha-build")
        home_cache = self.work / "webqa-runner/v3/home/profile.bin"
        home_cache.parent.mkdir(parents=True); home_cache.write_bytes(b"cache")
        worktree = self.work / "webqa-runner/v3/wt-b1716"
        worktree.mkdir(parents=True); (worktree / "tracked.bin").write_bytes(b"worktree")
        env = self.env(host="m1b")
        env["WRK_ARTIFACT_POLICY"] = str(ROOT / "director/artifact_policy.json")
        result = subprocess.run([str(WRK), "artifacts", "classify", "--root", "webqa-v3", "--json"],
                                cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)["jobs"]["root:webqa-v3"]
        self.assertEqual(report["webqa_sha_status"], "fail-closed")
        self.assertEqual(report["webqa_sha_retention"]["kept"], [str(build)])
        classes = report["classes"]
        self.assertIn("cache", classes)
        self.assertIn("worktree", classes)
        prune = subprocess.run([str(WRK), "prune", "--apply"], cwd=ROOT, env=env,
                               text=True, capture_output=True, timeout=45)
        self.assertEqual(prune.returncode, 0, prune.stderr)
        self.assertIn("protected-sha-source-invalid", prune.stdout)
        self.assertTrue(payload.exists(), prune.stdout)
        self.assertTrue(home_cache.exists(), prune.stdout)
        self.assertTrue(worktree.exists(), prune.stdout)

    def test_webqa_protected_sha_file_cases_and_freshness_mutant(self):
        import datetime
        import time
        from unittest import mock
        policy = json.loads((ROOT / "director/artifact_policy.json").read_text())
        env = self.env(host="m1b")
        env["WRK_ARTIFACT_POLICY"] = str(ROOT / "director/artifact_policy.json")
        env["WRK_LSOF_BIN"] = str(self.base / "lsof-clean")
        Path(env["WRK_LSOF_BIN"]).write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        Path(env["WRK_LSOF_BIN"]).chmod(0o755)
        source_root = self.jobs / "webqa-runner/v3"
        build_root = self.work / "webqa-runner/v3/builds"
        build_root.mkdir(parents=True)
        shas = ["f" * 40, "e" * 40, "d" * 40, "c" * 40, "b" * 40, "a" * 40]
        now = time.time()

        def make_builds(suffix):
            shutil.rmtree(build_root)
            build_root.mkdir(parents=True)
            paths = {}
            for index, sha in enumerate(shas):
                path = build_root / sha
                path.mkdir()
                payload = path / "app.bin"
                payload.write_bytes(sha.encode())
                stamp = now - index * 3600
                os.utime(payload, (stamp, stamp))
                os.utime(path, (stamp, stamp))
                paths[sha] = path
            return paths

        def write_sha_doc(path, *, age_hours=1, omit_written=False, main=None, releases=None, unparsable=False):
            path.parent.mkdir(parents=True, exist_ok=True)
            if unparsable:
                path.write_text("{not-json", encoding="utf-8")
                return
            written = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=age_hours)).isoformat().replace("+00:00", "Z")
            doc = {"main_sha": main or shas[-1], "release_shas": releases if releases is not None else [shas[-2]], "writer": "pa-integrator"}
            if not omit_written:
                doc["written_at"] = written
            path.write_text(json.dumps(doc), encoding="utf-8")

        # One arbiter fixture state is sufficient for every isolated temp run.
        init = subprocess.run([str(ROOT / "bin/arbiter"), "claim", "--job", "artifact-test-db", "--lane", "fixture", "--t", "T0"],
                              cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(init.returncode, 0, init.stderr)

        valid_paths = make_builds("valid-")
        sha_file = source_root / "protected-shas.json"
        write_sha_doc(sha_file)
        classified = subprocess.run([str(WRK), "artifacts", "classify", "--root", "webqa-v3", "--json"],
                                    cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(classified.returncode, 0, classified.stderr)
        retention = json.loads(classified.stdout)["jobs"]["root:webqa-v3"]["webqa_sha_retention"]
        self.assertEqual(set(retention["kept"]), {str(valid_paths[s]) for s in shas[:3] + shas[-2:]})
        self.assertEqual(retention["would_remove"], [str(valid_paths[shas[3]])])

        cases = (
            ("missing", None),
            ("unparsable", {"unparsable": True}),
            ("bad-main", {"main": "not-a-sha"}),
            ("bad-release", {"releases": ["g" * 40]}),
            ("stale", {"age_hours": 25}),
            ("missing-written-at", {"omit_written": True}),
        )
        for label, options in cases:
            with self.subTest(label=label):
                paths = make_builds(label + "-")
                if label == "missing":
                    sha_file.unlink(missing_ok=True)
                else:
                    write_sha_doc(sha_file, **options)
                report = subprocess.run([str(WRK), "artifacts", "classify", "--root", "webqa-v3", "--json"],
                                        cwd=ROOT, env=env, text=True, capture_output=True)
                self.assertEqual(report.returncode, 0, report.stderr)
                data = json.loads(report.stdout)["jobs"]["root:webqa-v3"]
                self.assertEqual(data["webqa_sha_status"], "fail-closed")
                self.assertEqual(set(data["webqa_sha_retention"]["kept"]), {str(p) for p in paths.values()})
                prune = subprocess.run([str(WRK), "prune", "--apply", "--job", "root:webqa-v3"], cwd=ROOT, env=env,
                                       text=True, capture_output=True, timeout=45)
                self.assertEqual(prune.returncode, 0, prune.stderr)
                self.assertTrue(all(p.exists() for p in paths.values()), prune.stdout)
                self.assertIn("protected-sha-source-invalid", prune.stdout)

        # Mutating the call site's age bound makes the stale listed SHA deletable.
        stale_paths = make_builds("stale-mutant-")
        write_sha_doc(sha_file, age_hours=25)
        source = WRK.read_text()
        mutation = "if age < 0 or age > 24 * 60 * 60:"
        mutant_source = source.replace(mutation, "if age < 0:")
        self.assertNotEqual(mutant_source, source)
        mutant = self.base / "stale-mutant-wrk"
        mutant.write_text(mutant_source, encoding="utf-8"); mutant.chmod(0o755)
        red = subprocess.run([str(mutant), "prune", "--apply", "--job", "root:webqa-v3"], cwd=ROOT, env=env,
                             text=True, capture_output=True, timeout=45)
        self.assertEqual(red.returncode, 0, red.stderr)
        self.assertFalse(stale_paths[shas[3]].exists(), red.stdout)
        # The correct freshness invariant above is what the mutant violates.
        with self.assertRaises(AssertionError):
            self.assertTrue(stale_paths[shas[3]].exists())

    def test_flat_intermediate_build_keeps_newest_three(self):
        self.policy["rows"] = [self.row("intermediate-build", "flat", "builds/*", keep_newest=3)]
        self.write_policy()
        builds = self.flat / "builds"; builds.mkdir()
        now = __import__("time").time()
        paths=[]
        for n in range(4):
            item=builds / ("sha-%d" % n); item.mkdir()
            (item / "payload.bin").write_bytes(bytes([n]))
            os.utime(item, (now+n, now+n)); paths.append(item)
        lsof=self.base / "lsof-clean"; lsof.write_text("#!/bin/sh\nexit 1\n",encoding="utf-8"); lsof.chmod(0o755)
        env=self.env(); env["WRK_LSOF_BIN"]=str(lsof)
        result=subprocess.run([str(WRK),"prune","--apply"],cwd=ROOT,env=env,
                              text=True,capture_output=True,timeout=45)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(paths[0].exists(),result.stdout)
        self.assertTrue(all(p.exists() for p in paths[1:]),result.stdout)

    def test_loader_schema_extensions_and_rejections(self):
        (self.jobs / "j1").mkdir()
        self.policy["rows"] = [self.row("intermediate-build", glob="build-*", keep_newest=3)]
        self.write_policy()
        self.assertEqual(self.run_wrk("artifacts", "classify").returncode, 0)
        bad_rows = [
            self.row("intermediate-build", glob="build-*", keep_newest=4),
            {**self.row("cache"), "unexpected": True},
            self.row("not-a-class"),
            self.row("cache", glob="/absolute"),
            self.row("cache", glob="a/../b"),
            self.row("cache", glob="{a,b}"),
            self.row("cache", "flat", "*.bin", job="j1"),
        ]
        for row in bad_rows:
            with self.subTest(row=row):
                self.policy["rows"] = [row]
                self.write_policy()
                refused = self.run_wrk("artifacts", "classify")
                self.assertNotEqual(refused.returncode, 0)
                if row["glob"] == "{a,b}":
                    self.assertIn("row 0", refused.stderr)
                    self.assertIn("brace", refused.stderr)
        # Old hk 2090's two unity rows remain byte-for-byte equivalent in meaning.
        shipped = json.loads((ROOT / "director/artifact_policy.json").read_text())
        unity = [r for r in shipped["rows"] if r.get("glob") == "unity/*/out"]
        self.assertEqual([(r["class"], r.get("keep_newest")) for r in unity],
                         [("intermediate-build", 2), ("cache", None)])
        # A legacy string root is accepted as per-job (exercised by this fixture).
        self.policy["rows"] = [self.row("cache", glob="cache")]
        self.write_policy()
        self.assertEqual(self.run_wrk("artifacts", "classify").returncode, 0)

    def test_mark_final_hash_event_and_refusals(self):
        job = self.jobs / "j1"
        job.mkdir()
        app = job / "release.apk"
        app.write_bytes(b"approved-final-build")
        marked = self.run_wrk("artifacts", "mark-final", "j1", "release.apk", "--by", "integrator")
        self.assertEqual(marked.returncode, 0, marked.stderr)
        marker = json.loads((job / "final-build.json").read_text())
        self.assertEqual(marker["sha256"], hashlib.sha256(app.read_bytes()).hexdigest())
        self.assertEqual(marker["bytes"], app.stat().st_size)
        self.assertEqual(marker["by"], "integrator")
        events = list((job / "events").glob("*job.final_build_marked.json"))
        self.assertEqual(len(events), 1)
        event = json.loads(events[0].read_text())
        self.assertEqual(event["sha256"], marker["sha256"])
        outside = self.base / "outside.bin"
        outside.write_bytes(b"outside")
        self.assertNotEqual(self.run_wrk("artifacts", "mark-final", "j1", str(outside), "--by", "integrator").returncode, 0)
        link = job / "linked.apk"
        link.symlink_to(app)
        self.assertNotEqual(self.run_wrk("artifacts", "mark-final", "j1", "linked.apk", "--by", "integrator").returncode, 0)
        cache = job / "cache"
        cache.mkdir(); (cache / "profile.bin").write_bytes(b"cache")
        self.policy["rows"] = [self.row("cache", glob="cache/**")]
        self.write_policy()
        refused = self.run_wrk("artifacts", "mark-final", "j1", "cache/profile.bin", "--by", "integrator")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("cache path", refused.stderr)

    def test_prune_keep_precedence_and_mutant_red(self):
        self.policy["rows"] = [
            self.row("intermediate-build", glob="run1-raw/**", keep_newest=1),
            self.row("record-text", glob="run1-raw/changed.txt"),
        ]
        self.write_policy()
        lsof = self.base / "lsof-clean"
        lsof.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        lsof.chmod(0o755)

        def prepare(job_id):
            job = self.jobs / job_id
            raw = job / "run1-raw"
            raw.mkdir(parents=True)
            old = raw / "changed.txt"; old.write_text("keep", encoding="utf-8")
            new = raw / "discard.bin"; new.write_text("newer", encoding="utf-8")
            now = __import__("time").time()
            os.utime(old, (now - 3600, now - 3600))
            os.utime(new, (now, now))
            events = job / "events"; events.mkdir()
            for index, (kind, payload) in enumerate((
                ("job.claim", {"owner_lane": "fixture", "task_id": 1}),
                ("job.spawned", {"owner_lane": "fixture", "pane_id": "fixture:p1"}),
            ), 1):
                doc = {"kind": kind, "job_id": job_id, "created_at": "2026-10-27T00:00:00Z", "payload": payload}
                (events / ("%05d-%s.json" % (index, kind))).write_text(json.dumps(doc), encoding="utf-8")
            return job, old

        env = self.env()
        env["WRK_LSOF_BIN"] = str(lsof)
        init = subprocess.run([str(ROOT / "bin/arbiter"), "claim", "--job", "artifact-test-db", "--lane", "fixture", "--t", "T0"],
                              cwd=ROOT, env=env, text=True, capture_output=True)
        self.assertEqual(init.returncode, 0, init.stderr)
        job, old = prepare("precedence")
        result = subprocess.run([str(WRK), "prune", "--apply", "--job", job.name],
                                cwd=ROOT, env=env, text=True, capture_output=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(old.exists(), result.stdout)
        self.assertIn("keep-class-precedence", result.stdout)

        classified = self.run_wrk("artifacts", "classify", "--job", "precedence", "--json")
        self.assertEqual(classified.returncode, 0, classified.stderr)
        conflict_rows = json.loads(classified.stdout)["jobs"]["precedence"]["conflicts"]
        changed_conflicts = [row for row in conflict_rows if row["path"].endswith("/run1-raw/changed.txt")]
        self.assertEqual(len(changed_conflicts), 1, changed_conflicts)
        self.assertEqual(changed_conflicts[0]["classes"], ["intermediate-build", "record-text"])

        source = WRK.read_text()
        mutated = source.replace('if [[ -n "$keep_conflict" ]]; then', "if false; then")
        self.assertNotEqual(mutated, source)
        mutant = self.base / "mutated-wrk"; mutant.write_text(mutated, encoding="utf-8"); mutant.chmod(0o755)
        job2, old2 = prepare("precedence-mutant")
        red = subprocess.run([str(mutant), "prune", "--apply", "--job", job2.name],
                             cwd=ROOT, env=env, text=True, capture_output=True, timeout=45)
        # The mutant removes the protected oldest file, making the invariant RED.
        self.assertEqual(red.returncode, 0, red.stderr)
        self.assertFalse(old2.exists(), red.stdout)

    def test_mutants_turn_required_invariants_red(self):
        job = self.jobs / "j1"
        job.mkdir()
        heavy = job / "unknown/sixty.bin"
        heavy.parent.mkdir(); heavy.write_bytes(b"x" * (60 * 1024 * 1024))
        self.policy["rows"] = [self.row("evidence", glob="evidence/*.bin")]
        self.write_policy()
        mutant_dir = self.base / "mutants"; mutant_dir.mkdir()
        source = WRK.read_text()
        skip = source.replace("elif not any(real==m or real.startswith(m+os.sep) for m in matched):", "elif False:")
        self.assertNotEqual(skip, source)
        skip_bin = mutant_dir / "skip-unclassified-wrk"; skip_bin.write_text(skip); skip_bin.chmod(0o755)
        report = self.run_wrk("artifacts", "classify", "--job", "j1", "--json", binary=skip_bin)
        self.assertEqual(json.loads(report.stdout)["jobs"]["j1"]["unclassified"], [])
        self.assertFalse(any(x["path"] == str(heavy) for x in json.loads(report.stdout)["jobs"]["j1"]["unclassified"]))

        cache = job / "cache"; cache.mkdir(); (cache / "payload.bin").write_bytes(b"cache")
        self.policy["rows"] = [self.row("cache", glob="cache/**")]; self.write_policy()
        accept = source.replace('[[ "$is_cache" != yes ]] || die "artifacts mark-final refuses a cache path"',
                                '[[ "$is_cache" != no ]] || die "artifacts mark-final refuses a cache path"')
        self.assertNotEqual(accept, source)
        accept_bin = mutant_dir / "accept-cache-wrk"; accept_bin.write_text(accept); accept_bin.chmod(0o755)
        final = self.run_wrk("artifacts", "mark-final", "j1", "cache/payload.bin", "--by", "integrator", binary=accept_bin)
        self.assertEqual(final.returncode, 0, final.stderr)
        # Both mutants violate their respective refusal/reporting assertions.
        with self.assertRaises(AssertionError):
            self.assertTrue(any(x["path"] == str(heavy) for x in json.loads(report.stdout)["jobs"]["j1"]["unclassified"]))
        with self.assertRaises(AssertionError):
            self.assertNotEqual(final.returncode, 0)

    def test_schema_filter_mutants_turn_their_contracts_red(self):
        source = WRK.read_text()
        mutants = self.base / "schema-mutants"; mutants.mkdir()

        def mutant(name, old, new):
            changed = source.replace(old, new)
            self.assertNotEqual(changed, source, name)
            binary = mutants / name
            binary.write_text(changed, encoding="utf-8"); binary.chmod(0o755)
            return binary

        (self.flat / "m1.bin").write_bytes(b"host-bound")
        self.policy["rows"] = [self.row("evidence", "flat", "*.bin", host="m1")]
        self.write_policy()
        no_host_filter = mutant("host-filter", "if (rhost and rhost != host) or (only_root and name != only_root): continue",
                                "if (only_root and name != only_root): continue")
        host_leak = self.run_wrk("artifacts", "classify", "--root", "flat", "--json", binary=no_host_filter, host="m2")
        self.assertIn("evidence", json.loads(host_leak.stdout)["jobs"]["root:flat"]["classes"])
        with self.assertRaises(AssertionError):
            self.assertNotIn("evidence", json.loads(host_leak.stdout)["jobs"]["root:flat"]["classes"])

        flat_job = mutant("flat-job", 'if job and root_kind != "per-job":', "if False:")
        self.policy["rows"] = [self.row("cache", "flat", "*.bin", job="j1")]
        self.write_policy()
        bad_flat_job = self.run_wrk("artifacts", "classify", binary=flat_job)
        self.assertEqual(bad_flat_job.returncode, 0)
        with self.assertRaises(AssertionError):
            self.assertNotEqual(bad_flat_job.returncode, 0)

        (self.jobs / "j1").mkdir(); (self.jobs / "j2").mkdir()
        (self.jobs / "j2/only.txt").write_text("wrong job", encoding="utf-8")
        self.policy["rows"] = [self.row("record-text", glob="only.txt", job="j1")]
        self.write_policy()
        no_job_filter = mutant("job-filter", "if row['job'] and row['job'] != job: continue", "if False: continue")
        job_leak = self.run_wrk("artifacts", "classify", "--job", "j2", "--json", binary=no_job_filter)
        self.assertIn("record-text", json.loads(job_leak.stdout)["jobs"]["j2"]["classes"])
        with self.assertRaises(AssertionError):
            self.assertNotIn("record-text", json.loads(job_leak.stdout)["jobs"]["j2"]["classes"])

        accept_four = mutant("keep-four", "keep not in (1, 2, 3)", "keep not in (1, 2, 3, 4)")
        self.policy["rows"] = [self.row("intermediate-build", glob="build-*", keep_newest=4)]
        self.write_policy()
        four_ok = self.run_wrk("artifacts", "classify", binary=accept_four)
        self.assertEqual(four_ok.returncode, 0)
        with self.assertRaises(AssertionError):
            self.assertNotEqual(four_ok.returncode, 0)

        break_legacy_root = mutant("bare-root", 'if isinstance(spec, str):', "if False:")
        self.policy["roots"]["jobs"] = "herdr-inbox/jobs"
        self.policy["rows"] = [self.row("cache", glob="cache")]
        self.write_policy()
        legacy_broken = self.run_wrk("artifacts", "classify", binary=break_legacy_root)
        self.assertNotEqual(legacy_broken.returncode, 0)

        accept_braces = mutant("brace-glob", 'if "{" in pat or "}" in pat:', "if False:")
        self.policy["rows"] = [self.row("cache", glob="{a,b}")]
        self.write_policy()
        braces_ok = self.run_wrk("artifacts", "classify", binary=accept_braces)
        self.assertEqual(braces_ok.returncode, 0)
        with self.assertRaises(AssertionError):
            self.assertNotEqual(braces_ok.returncode, 0)


if __name__ == "__main__":
    unittest.main()
