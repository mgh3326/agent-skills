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


def run_report(jobs_root: Path, status: dict | str, *extra: str) -> subprocess.CompletedProcess:
    payload = status if isinstance(status, str) else json.dumps(status)
    return subprocess.run(
        [sys.executable, str(REPORT), "--jobs-root", str(jobs_root), *extra],
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

    def test_unparseable_stdin_exits_2(self) -> None:
        proc = run_report(self.jobs_root, "not json {")
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(len(proc.stderr.strip().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
