"""Orphaned leased jobs: CLI tests against a private, disposable SQLite DB."""

import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ARBITER = Path(os.environ.get("ARBITER_ORPHAN_TEST_BIN", ROOT / "bin/arbiter"))


class OrphanRelease(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="arbiter-orphan-")
        self.root = Path(self.tmp.name)
        self.env = dict(os.environ, WRK_TEST_MODE="1")
        for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                     "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "CODEX_HOME",
                     "ARBITER_INBOX_ROOT", "TMPDIR"):
            path = self.root / name.lower()
            path.mkdir()
            self.env[name] = str(path)
        self.env["SCOPEFUEL_BIN"] = str(ROOT / "tests/fixtures/scopefuel")
        self.agents = self.root / "agents.json"
        self.set_agents([])
        herdr = self.root / "herdr"
        herdr.write_text("#!/bin/sh\ncat " + str(self.agents) + "\n")
        herdr.chmod(0o755)
        self.env["HERDR_BIN"] = str(herdr)
        gate = subprocess.run([self.env["SCOPEFUEL_BIN"], "gate", "-m", "codex-max"],
                              env=self.env, capture_output=True, text=True, check=True)
        self.gate = self.root / "gate.out"
        self.gate.write_text(gate.stdout)
        self.db = Path(self.env["XDG_DATA_HOME"]) / "arbiter/state.db"

    def tearDown(self):
        self.tmp.cleanup()

    def set_agents(self, entries):
        self.agents.write_text(json.dumps({"result": {"agents": [
            {"name": name, "agent_status": status} for name, status in entries]}}))

    def run_arb(self, *args, expected=0):
        result = subprocess.run([sys.executable, str(ARBITER), *args], env=self.env,
                                text=True, capture_output=True, timeout=15)
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
        return result

    def claim_quota(self, job):
        self.run_arb("claim", "--job", job, "--lane", "fixture", "--t", "T1")
        self.run_arb("lease", "--job", job, "--kind", "quota_pool",
                     "--profile", "codex-max", "--gate-output", str(self.gate))

    def remove_quota(self, job):
        with sqlite3.connect(self.db) as con:
            con.execute("DELETE FROM quota_pool_records WHERE job_id = ?", (job,))

    def state(self, job):
        data = json.loads(self.run_arb("status", "--job", job, "--json").stdout)
        return data["jobs"][0]["state"], data

    def events(self, job):
        directory = Path(self.env["ARBITER_INBOX_ROOT"]) / job / "events"
        return [json.loads(p.read_text()) for p in directory.glob("*-job.orphan_release.json")]

    def gc(self, expected=0):
        return self.run_arb("gc", "--herdr-agent-list", str(self.agents), "--json", expected=expected)

    def test_gc_releases_absent_quota_job_and_reclaim_succeeds(self):
        self.claim_quota("gone")
        self.gc()
        state, data = self.state("gone")
        self.assertEqual(state, "released", "gc did not release orphaned leased job")
        self.assertEqual(data["quota_pool_records"], [])
        events = self.events("gone")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["payload"]["prior_state"], "leased")
        self.assertEqual(events[0]["payload"]["agent_label"], "gone")
        self.assertIn("reason", events[0]["payload"])
        self.run_arb("claim", "--job", "gone", "--lane", "fixture", "--t", "T1",
                     "--reclaim-released")

    def test_present_idle_done_blocked_and_working_remain_leased(self):
        states = ("idle", "done", "blocked", "working")
        for status in states:
            self.claim_quota(status)
        self.set_agents([(s, s) for s in states])
        self.gc()
        for status in states:
            with self.subTest(status=status):
                state, _ = self.state(status)
                self.assertEqual(state, "leased", "present agent was released: " + status)
                self.assertEqual(self.events(status), [])
                result = self.run_arb("release", "--force", "--job", status, expected=None)
                self.assertNotEqual(result.returncode, 0, "force released live " + status)

    def test_unknown_status_refuses_and_preserves_quota(self):
        self.claim_quota("uncertain")
        self.set_agents([("uncertain", "unknown")])
        self.gc(expected=6)
        state, data = self.state("uncertain")
        self.assertEqual(state, "leased")
        self.assertEqual(len(data["quota_pool_records"]), 1)
        self.assertEqual(self.events("uncertain"), [])
        result = self.run_arb("release", "--force", "--job", "uncertain", expected=None)
        self.assertNotEqual(result.returncode, 0)

    def test_unknown_without_rows_does_not_block_independent_cleanup(self):
        self.claim_quota("unknown-empty")
        self.remove_quota("unknown-empty")
        self.claim_quota("gone-with-unknown")
        self.set_agents([("unknown-empty", "unknown")])
        result = json.loads(self.gc().stdout)
        self.assertEqual(self.state("unknown-empty")[0], "leased")
        self.assertEqual(self.events("unknown-empty"), [])
        state, data = self.state("gone-with-unknown")
        self.assertEqual(state, "released")
        self.assertEqual(data["quota_pool_records"], [])
        self.assertEqual(len(self.events("gone-with-unknown")), 1)
        self.assertIn("unknown-empty", [item["job_id"] for item in result["unresolved_orphans"]])
        forced = self.run_arb("release", "--force", "--job", "unknown-empty", expected=None)
        self.assertNotEqual(forced.returncode, 0)
        self.assertIn("unknown", forced.stderr.lower())

    def test_unmapped_empty_orphan_does_not_block_independent_cleanup(self):
        self.claim_quota("legacy-empty")
        self.remove_quota("legacy-empty")
        with sqlite3.connect(self.db) as con:
            con.execute("DELETE FROM events WHERE job_id = ? AND kind = 'job.claim'", ("legacy-empty",))
        self.claim_quota("gone-with-legacy")
        result = json.loads(self.gc().stdout)
        self.assertEqual(self.state("legacy-empty")[0], "leased")
        self.assertEqual(self.events("legacy-empty"), [])
        state, data = self.state("gone-with-legacy")
        self.assertEqual(state, "released")
        self.assertEqual(data["quota_pool_records"], [])
        self.assertEqual(len(self.events("gone-with-legacy")), 1)
        self.assertIn("legacy-empty", [item["job_id"] for item in result["unresolved_orphans"]])
        forced = self.run_arb("release", "--force", "--job", "legacy-empty", expected=None)
        self.assertNotEqual(forced.returncode, 0)
        self.assertIn("mapping", forced.stderr.lower())

    def test_unmapped_owner_refuses_without_deleting_quota(self):
        self.claim_quota("unmapped")
        with sqlite3.connect(self.db) as con:
            con.execute("DELETE FROM events WHERE job_id = ? AND kind = 'job.claim'", ("unmapped",))
        self.gc(expected=6)
        state, data = self.state("unmapped")
        self.assertEqual(state, "leased")
        self.assertEqual(len(data["quota_pool_records"]), 1)
        self.assertEqual(self.events("unmapped"), [])

    def test_ambiguous_empty_orphan_does_not_block_independent_cleanup(self):
        self.claim_quota("ambiguous-empty")
        self.remove_quota("ambiguous-empty")
        with sqlite3.connect(self.db) as con:
            row = con.execute("SELECT payload, created_at FROM events WHERE job_id = ? AND kind = 'job.claim'",
                              ("ambiguous-empty",)).fetchone()
            claim = json.loads(row[0])
            claim["payload"]["agent_label"] = "different-agent"
            seq = con.execute("SELECT MAX(seq) FROM events WHERE job_id = ?", ("ambiguous-empty",)).fetchone()[0] + 1
            con.execute("INSERT INTO events (job_id, seq, kind, payload, created_at) VALUES (?, ?, ?, ?, ?)",
                        ("ambiguous-empty", seq, "job.claim", json.dumps(claim), row[1]))
        self.claim_quota("gone-with-ambiguous")
        result = json.loads(self.gc().stdout)
        self.assertEqual(self.state("ambiguous-empty")[0], "leased")
        self.assertEqual(self.events("ambiguous-empty"), [])
        state, data = self.state("gone-with-ambiguous")
        self.assertEqual(state, "released")
        self.assertEqual(data["quota_pool_records"], [])
        self.assertIn("ambiguous-empty", [item["job_id"] for item in result["unresolved_orphans"]])
        forced = self.run_arb("release", "--force", "--job", "ambiguous-empty", expected=None)
        self.assertNotEqual(forced.returncode, 0)

    def test_path_lease_blocks_gc_and_forced_release(self):
        self.claim_quota("lease-left")
        self.run_arb("lease", "--job", "lease-left", "--resource", "resource-one", "--kind", "path")
        self.gc()
        state, data = self.state("lease-left")
        self.assertEqual(state, "leased", "lease left but gc released the job")
        self.assertEqual(len(data["leases"]), 1)
        self.assertEqual(self.events("lease-left"), [])
        result = self.run_arb("release", "--force", "--job", "lease-left", expected=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lease", result.stderr.lower())

    def test_force_releases_only_absent_job_with_no_rows(self):
        self.claim_quota("manual")
        self.remove_quota("manual")
        self.run_arb("release", "--force", "--job", "manual")
        self.assertEqual(self.state("manual")[0], "released")
        events = self.events("manual")
        self.assertEqual(len(events), 1)
        self.assertTrue(events[0]["payload"]["forced"])

    def test_force_refuses_unknown_and_quota_left(self):
        self.claim_quota("quota-left")
        result = self.run_arb("release", "--force", "--job", "quota-left", expected=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("quota", result.stderr.lower())
        self.remove_quota("quota-left")
        self.set_agents([("quota-left", "unknown")])
        result = self.run_arb("release", "--force", "--job", "quota-left", expected=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown", result.stderr.lower())
        self.assertEqual(self.state("quota-left")[0], "leased")

    def test_gc_and_force_race_write_one_transition(self):
        self.claim_quota("race")
        self.remove_quota("race")
        a = subprocess.Popen([sys.executable, str(ARBITER), "gc", "--herdr-agent-list", str(self.agents)],
                             env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        b = subprocess.Popen([sys.executable, str(ARBITER), "release", "--force", "--job", "race"],
                             env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        a.communicate(timeout=15)
        b.communicate(timeout=15)
        self.assertEqual(self.state("race")[0], "released")
        self.assertEqual(len(self.events("race")), 1, "concurrent transitions duplicated the audit")

    def test_orphan_release_mutants(self):
        source = ARBITER.read_text()
        mutants = [
            ("gc", [("for job_id, decision in orphan_decisions:\n", "for job_id, decision in []:\n")],
             "test_gc_releases_absent_quota_job_and_reclaim_succeeds"),
            ("unknown", [('    if "unknown" in statuses:\n        reason = f"job {job_id} agent {agent_label} has unknown status"\n',
                          '    if False:\n        reason = f"job {job_id} agent {agent_label} has unknown status"\n'),
                         ('    if matched:  # hk1991-orphan-release\n',
                          '    if matched and "unknown" not in statuses:\n')],
             "test_unknown_without_rows_does_not_block_independent_cleanup"),
            ("lease", [("    if leases or pools:\n", "    if pools:\n")],
             "test_path_lease_blocks_gc_and_forced_release"),
            ("idle", [('    if matched:  # hk1991-orphan-release\n',
                       '    if matched and "working" in statuses:\n')],
             "test_present_idle_done_blocked_and_working_remain_leased"),
            ("unmapped-rollback", [('    if agent_label is None:\n        reason = f"job {job_id} has no exact agent_label mapping"\n',
                                   '    if agent_label is None:\n        reason = f"job {job_id} has no exact agent_label mapping"\n        raise ArbiterError(EXIT_STORAGE, reason)\n')],
             "test_unmapped_empty_orphan_does_not_block_independent_cleanup"),
        ]
        for name, changes, case in mutants:
            with self.subTest(mutant=name):
                mutated = source
                for before, after in changes:
                    self.assertEqual(mutated.count(before), 1, "mutant anchor changed: " + name)
                    mutated = mutated.replace(before, after, 1)
                binary = self.root / ("mutant-" + name)
                binary.write_text(mutated)
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                         "OrphanRelease." + case],
                                        env=dict(self.env, ARBITER_ORPHAN_TEST_BIN=str(binary)),
                                        capture_output=True, text=True, timeout=45)
                self.assertNotEqual(result.returncode, 0, "mutant survived: " + name)
                self.assertIn("AssertionError:", result.stderr)
                self.assertNotIn("ERROR:", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
