"""Fixture tests for director/bin/quota-stale-report (b953, hk 1807)."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / "director" / "bin" / "quota-stale-report"

NOW = "2026-10-21T12:00:00+00:00"


def run_report(jobs_root: Path, status: dict | str, *extra: str,
               script: Path = REPORT) -> subprocess.CompletedProcess:
    payload = status if isinstance(status, str) else json.dumps(status)
    return subprocess.run(
        [sys.executable, str(script), "--jobs-root", str(jobs_root), *extra],
        input=payload, text=True, capture_output=True,
    )


def write_events(jobs_root: Path, job: str, kinds: list[str]) -> None:
    events = jobs_root / job / "events"
    events.mkdir(parents=True)
    for seq, kind in enumerate(kinds, 1):
        body = {"job_id": job, "seq": seq, "kind": kind, "payload": {},
                "created_at": NOW}
        (events / f"{seq:05d}-{kind}.json").write_text(json.dumps(body) + "\n")


def record(job: str, started: str, pool: str = "codex",
           profile: str = "codex-max") -> dict:
    return {"job_id": job, "pool": pool, "profile": profile,
            "started_at": started}


class QuotaStaleReport(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.jobs_root = Path(self.temp.name) / "jobs"
        self.jobs_root.mkdir()

    def status(self, records: list[dict]) -> dict:
        return {"ok": True, "now": NOW, "quota_pool_records": records}

    def test_all_categories(self) -> None:
        write_events(self.jobs_root, "j-done",
                     ["job.spawned", "quota_pool.record", "job.completed"])
        write_events(self.jobs_root, "j-reaped",
                     ["quota_pool.record", "job.reaped"])
        write_events(self.jobs_root, "j-revoked",
                     ["quota_pool.record", "job.revoked"])
        write_events(self.jobs_root, "j-lost",
                     ["quota_pool.record", "job.lost"])
        write_events(self.jobs_root, "j-rerecord",
                     ["quota_pool.record", "quota_pool.release",
                      "quota_pool.record"])
        write_events(self.jobs_root, "j-live",
                     ["job.spawned", "quota_pool.record"])
        write_events(self.jobs_root, "j-recent",
                     ["quota_pool.record", "job.completed"])
        # j-gone has a leaked record but no events dir at all.
        records = [
            record("j-done", "2026-10-21T02:00:00+00:00"),
            record("j-reaped", "2026-10-20T20:00:00+00:00", pool="gpt"),
            record("j-revoked", "2026-10-21T00:00:00+00:00"),
            record("j-lost", "2026-10-21T00:30:00+00:00"),
            record("j-rerecord", "2026-10-20T10:00:00+00:00"),
            record("j-live", "2026-10-19T10:00:00+00:00"),
            record("j-recent", "2026-10-21T08:00:00+00:00"),
            record("j-gone", "2026-10-18T00:00:00+00:00"),
        ]
        proc = run_report(self.jobs_root, self.status(records))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        expected = "\n".join([
            "j-done\tcodex\tcodex-max\t2026-10-21T02:00:00+00:00\t10.00\tcompleted_no_release\tjob.completed",
            "j-gone\tcodex\tcodex-max\t2026-10-18T00:00:00+00:00\t84.00\tno_events_dir\t-",
            "j-live\tcodex\tcodex-max\t2026-10-19T10:00:00+00:00\t50.00\tno_terminal\tquota_pool.record",
            "j-lost\tcodex\tcodex-max\t2026-10-21T00:30:00+00:00\t11.50\tlost_or_revoked_no_release\tjob.lost",
            "j-reaped\tgpt\tcodex-max\t2026-10-20T20:00:00+00:00\t16.00\treaped_no_release\tjob.reaped",
            "j-recent\tcodex\tcodex-max\t2026-10-21T08:00:00+00:00\t4.00\trecent\tjob.completed",
            "j-rerecord\tcodex\tcodex-max\t2026-10-20T10:00:00+00:00\t26.00\trerecorded_after_release\tquota_pool.record",
            "j-revoked\tcodex\tcodex-max\t2026-10-21T00:00:00+00:00\t12.00\tlost_or_revoked_no_release\tjob.revoked",
            "summary\tcodex\tcompleted_no_release\t1",
            "summary\tcodex\tlost_or_revoked_no_release\t2",
            "summary\tcodex\tno_events_dir\t1",
            "summary\tcodex\tno_terminal\t1",
            "summary\tcodex\trecent\t1",
            "summary\tcodex\trerecorded_after_release\t1",
            "summary\tgpt\treaped_no_release\t1",
        ]) + "\n"
        self.assertEqual(proc.stdout, expected)
        self.assertEqual(proc.stderr, "")

    def test_since_hours_flag_moves_cut(self) -> None:
        write_events(self.jobs_root, "j-edge", ["job.completed"])
        records = [record("j-edge", "2026-10-21T08:00:00+00:00")]
        proc = run_report(self.jobs_root, self.status(records), "--since-hours", "3")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("\tcompleted_no_release\t", proc.stdout)
        proc = run_report(self.jobs_root, self.status(records), "--since-hours", "5")
        self.assertIn("\trecent\t", proc.stdout)

    def assert_revived_job_is_not_terminal(self, proc: subprocess.CompletedProcess) -> None:
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("\tno_terminal\t", proc.stdout)
        self.assertNotIn("_no_release\t", proc.stdout)

    def check_revival_after_terminal(self, revival_kind: str) -> None:
        job = "j-revived"
        write_events(self.jobs_root, job,
                     ["quota_pool.record", "job.completed", revival_kind])
        proc = run_report(self.jobs_root, self.status(
            [record(job, "2026-10-19T00:00:00+00:00")]))
        self.assert_revived_job_is_not_terminal(proc)
        self.assertIn(f"\t{revival_kind}\n", proc.stdout)

    def test_claim_after_terminal_is_not_stale_terminal(self) -> None:
        self.check_revival_after_terminal("job.claim")

    def test_reclaim_after_terminal_is_not_stale_terminal(self) -> None:
        self.check_revival_after_terminal("job.reclaim")

    def test_spawned_after_terminal_is_not_stale_terminal(self) -> None:
        self.check_revival_after_terminal("job.spawned")

    def test_reprompted_after_terminal_is_not_stale_terminal(self) -> None:
        self.check_revival_after_terminal("job.reprompted")

    def test_recent_revived_job_is_no_terminal_not_recent(self) -> None:
        write_events(self.jobs_root, "j-recent-revived",
                     ["quota_pool.record", "job.completed", "job.spawned"])
        proc = run_report(self.jobs_root, self.status(
            [record("j-recent-revived", "2026-10-21T11:00:00+00:00")]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("\tno_terminal\t", proc.stdout)
        self.assertNotIn("\trecent\t", proc.stdout)

    def test_all_terminal_kinds_have_a_report_category(self) -> None:
        expected = {
            "job.completed": "completed_no_release",
            "job.completion": "completed_no_release",
            "job.joined": "completed_no_release",
            "job.handed_off": "completed_no_release",
            "job.reaped": "reaped_no_release",
            "job.lost": "lost_or_revoked_no_release",
            "job.revoked": "lost_or_revoked_no_release",
        }
        records = []
        for index, (kind, category) in enumerate(expected.items()):
            job = f"j-terminal-{index}"
            write_events(self.jobs_root, job, ["quota_pool.record", kind])
            records.append(record(job, "2026-10-19T00:00:00+00:00"))
        proc = run_report(self.jobs_root, self.status(records))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for category in expected.values():
            self.assertIn(f"\t{category}\t", proc.stdout)

    def test_revival_ordering_check_has_assertion_red_mutant(self) -> None:
        write_events(self.jobs_root, "j-revived",
                     ["quota_pool.record", "job.completed", "job.reclaim"])
        status = self.status([record("j-revived", "2026-10-19T00:00:00+00:00")])
        source = REPORT.read_text(encoding="utf-8")
        guard = '    if revived_after_terminal(kinds):\n        return "no_terminal"\n'
        self.assertIn(guard, source)
        with tempfile.TemporaryDirectory() as scratch:
            mutant = Path(scratch) / "quota-stale-report-mutant"
            mutant.write_text(source.replace(guard, "", 1), encoding="utf-8")
            proc = run_report(self.jobs_root, status, script=mutant)
            with self.assertRaises(AssertionError):
                self.assert_revived_job_is_not_terminal(proc)

    def test_release_after_record_is_not_no_release(self) -> None:
        # Terminal, but the release lands after the last record: the leaked
        # row bucket does not apply; the rerecord bucket needs a later record.
        write_events(self.jobs_root, "j-clean",
                     ["quota_pool.record", "job.completed", "quota_pool.release"])
        proc = run_report(self.jobs_root, self.status(
            [record("j-clean", "2026-10-20T00:00:00+00:00")]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("\tno_terminal\t", proc.stdout)

    def test_empty_records_and_missing_events_dir(self) -> None:
        proc = run_report(self.jobs_root, self.status([]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "")
        # Missing events dir on the record still exits 0.
        proc = run_report(self.jobs_root, self.status(
            [record("ghost", "2026-10-20T00:00:00+00:00")]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("\tno_events_dir\t-\n", proc.stdout)

    def test_ok_false_exits_2_no_stdout(self) -> None:
        proc = run_report(self.jobs_root,
                          {"ok": False, "now": NOW, "quota_pool_records": []})
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(len(proc.stderr.strip().splitlines()), 1)
        self.assertTrue(proc.stderr.startswith("quota-stale-report:"))
        self.assertIn("ok false", proc.stderr)

    def test_ok_false_with_records_still_exits_2(self) -> None:
        write_events(self.jobs_root, "j-done",
                     ["quota_pool.record", "job.completed"])
        proc = run_report(self.jobs_root,
                          {"ok": False, "now": NOW,
                           "quota_pool_records": [record("j-done", "2026-10-21T02:00:00+00:00")]})
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertNotIn("j-done", proc.stdout)

    def test_ok_false_appends_error_truncated(self) -> None:
        proc = run_report(self.jobs_root,
                          {"ok": False, "error": "state.db unreadable"})
        self.assertEqual(proc.returncode, 2)
        self.assertIn("state.db unreadable", proc.stderr)
        long_error = "x" * 500
        proc = run_report(self.jobs_root,
                          {"ok": False, "error": long_error})
        self.assertEqual(proc.returncode, 2)
        self.assertIn("x" * 200, proc.stderr)
        self.assertNotIn("x" * 201, proc.stderr)

    def test_ok_false_non_string_error_ignored(self) -> None:
        proc = run_report(self.jobs_root, {"ok": False, "error": 42})
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertIn("ok false", proc.stderr)

    def test_ok_string_false_and_null_count_as_not_true(self) -> None:
        for bad in ("false", None):
            proc = run_report(self.jobs_root, {"ok": bad})
            self.assertEqual(proc.returncode, 2, f"ok={bad!r}")
            self.assertEqual(proc.stdout, "")

    def test_ok_absent_keeps_previous_behaviour(self) -> None:
        write_events(self.jobs_root, "j-done",
                     ["quota_pool.record", "job.completed"])
        records = [record("j-done", "2026-10-21T02:00:00+00:00")]
        status = {"now": NOW, "quota_pool_records": records}
        proc = run_report(self.jobs_root, status)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with_ok = run_report(self.jobs_root,
                             {"ok": True, **status})
        self.assertEqual(with_ok.returncode, 0, with_ok.stderr)
        self.assertEqual(proc.stdout, with_ok.stdout)

    def test_ok_guard_red_mutant(self) -> None:
        status = {"ok": False, "now": NOW, "quota_pool_records": []}
        source = REPORT.read_text(encoding="utf-8")
        guard = "    if status.get(\"ok\", True) is not True:\n"
        self.assertIn(guard, source)
        with tempfile.TemporaryDirectory() as scratch:
            mutant = Path(scratch) / "quota-stale-report-mutant"
            mutant.write_text(source.replace(guard, "    if False:\n", 1),
                              encoding="utf-8")
            proc = run_report(self.jobs_root, status, script=mutant)
            self.assertNotEqual(proc.returncode, 2)

    def test_unparseable_stdin_exits_2(self) -> None:
        proc = run_report(self.jobs_root, "not json {")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(len(proc.stderr.strip().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
