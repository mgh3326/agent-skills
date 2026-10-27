#!/usr/bin/env python3
"""Contract tests for the read-only PA-REVIEW scanner."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "director/bin/pa-review-scan"
FIXTURE = ROOT / "tests/fixtures/pa-review-comments.json"


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pa-review-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        for name in ("cache", "config", "data", "state", "codex", "inbox", "tmp"):
            (root / name).mkdir()
        bindir = root / "bin"
        bindir.mkdir()
        stub = bindir / "handoffkeep"
        shutil.copyfile(ROOT / "tests/fixtures/pa-review-hk.py", stub)
        stub.chmod(0o755)
        fixture = root / "comments.json"
        shutil.copyfile(FIXTURE, fixture)
        self.call_log = root / "calls.txt"
        self.env = os.environ.copy()
        self.env.update({
            "HOME": str(self.home), "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data"),
            "XDG_STATE_HOME": str(root / "state"), "CODEX_HOME": str(root / "codex"),
            "ARBITER_INBOX_ROOT": str(root / "inbox"), "TMPDIR": str(root / "tmp"),
            "WRK_TEST_MODE": "1", "PA_REVIEW_FIXTURE": str(fixture),
            "PA_REVIEW_CALL_LOG": str(self.call_log),
            "PATH": str(bindir) + os.pathsep + os.environ.get("PATH", ""),
        })

    def run_scan(self, *args):
        return subprocess.run([str(SCANNER), *args], env=self.env, text=True,
                              capture_output=True, check=False)

    def test_json_combines_forms_orders_final_and_reports_guards(self):
        result = self.run_scan("--task", "1935", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["tasks"][0]["task"], 1935)
        job = data["tasks"][0]["jobs"]["b1935"]
        self.assertEqual(job["forms"], ["early", "v1"])
        self.assertEqual(job["rounds"], [1, 1, 2, 3])
        self.assertEqual(job["final"]["outcome"], "accepted")
        self.assertEqual(job["final"]["head"], "abcdef1")
        self.assertEqual(job["reworks"], 2)
        self.assertTrue(job["counted"])
        self.assertTrue(job["lines"][0]["round_derived"])
        self.assertEqual(job["final"]["note"], "detail=clean #좋음")
        self.assertEqual(data["errors"][0]["comment_id"], 90)
        self.assertEqual(data["warnings"][0]["comment_id"], 91)
        self.assertFalse(data["tasks"][0]["jobs"]["warn"]["counted"])

    def test_outcomes_reason_counting_derived_round_and_time_ties(self):
        result = self.run_scan("--task", "1935", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        jobs = data["tasks"][0]["jobs"]
        self.assertEqual(jobs["notaccepted"]["final"]["outcome"], "not-accepted")
        self.assertTrue(jobs["notaccepted"]["counted"])
        self.assertFalse(jobs["excluded"]["counted"])
        self.assertFalse(jobs["quota"]["counted"])
        self.assertFalse(jobs["tooling"]["counted"])
        self.assertFalse(jobs["host"]["counted"])
        self.assertFalse(jobs["cancel"]["counted"])
        self.assertTrue(jobs["scope"]["counted"])
        self.assertEqual(jobs["derived"]["final"]["round"], 1)
        self.assertTrue(jobs["derived"]["final"]["round_derived"])
        self.assertEqual(jobs["clock"]["final"]["comment_id"], 102)
        self.assertEqual(jobs["clock"]["final"]["outcome"], "rework")
        self.assertEqual(jobs["clock"]["final"]["round"], 2)
        self.assertEqual(jobs["outoftime"]["rounds"], [2, 1])
        self.assertEqual(jobs["outoftime"]["final"]["outcome"], "accepted")
        self.assertEqual(jobs["free-text"]["final"]["reason"], "equals=a:b and more")
        self.assertEqual(data["tasks"][0]["deciding_job"], "free-text")

    def test_malformed_prefix_lines_are_errors_but_mentions_and_other_authors_are_ignored(self):
        result = self.run_scan("--task", "1935", "--json")
        data = json.loads(result.stdout)
        ids = [item["comment_id"] for item in data["errors"]]
        self.assertIn(94, ids)
        messages = [item["message"] for item in data["errors"]]
        self.assertIn("unknown v1 reason code", messages)
        self.assertIn("task id does not match posted task", messages)
        jobs = data["tasks"][0]["jobs"]
        self.assertNotIn("ignored", jobs)
        self.assertEqual(jobs["amb"]["final"]["form"], "early")
        self.assertIn("v1 task=1935 job=what", jobs["amb"]["final"]["reason"])
        self.assertNotIn("bad", jobs)  # unknown v1 code is never reinterpreted as early form
        self.assertNotIn("wrongtask", jobs)

    def test_strict_near_matches_are_individually_reported_as_errors(self):
        result = self.run_scan("--task", "1935", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        errors = [item for item in data["errors"] if item["comment_id"] == 94]
        self.assertEqual([item["line"] for item in errors], list(range(1, 8)) + list(range(9, 22)))
        jobs = data["tasks"][0]["jobs"]
        self.assertNotIn("lower-tag", jobs)
        for name in ("badspace", "tab", "trail", "case", "dash", "upper", "order",
                     "outcome", "empty", "unknown", "version", "zero", "doublezero",
                     "lowercasekey", "longhead", "shorthead", "earlyempty"):
            self.assertNotIn(name, jobs)

    def test_zero_round_is_an_error_and_does_not_abort_other_jobs(self):
        result = self.run_scan("--task", "1935", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        zero_errors = [item for item in data["errors"]
                       if item["comment_id"] == 94 and item["message"] == "round must be positive"]
        self.assertEqual([item["line"] for item in zero_errors], [16, 17])
        jobs = data["tasks"][0]["jobs"]
        self.assertNotIn("zero", jobs)
        self.assertNotIn("doublezero", jobs)
        self.assertEqual(jobs["b1935"]["final"]["outcome"], "accepted")

    def test_early_rounds_derive_from_job_line_order_and_unicode_separator_stays_in_note(self):
        result = self.run_scan("--task", "1935", "--task", "1891", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        tasks_by_id = {item["task"]: item for item in data["tasks"]}
        task1935, task1891 = tasks_by_id[1935], tasks_by_id[1891]
        early = task1935["jobs"]["early-sequence"]
        self.assertEqual(early["rounds"], [1, 2])
        self.assertTrue(all(item["round_derived"] for item in early["lines"]))
        self.assertEqual(early["final"]["reason"], "second")
        unicode_job = task1935["jobs"]["unicode-line"]
        self.assertIn("\u2028PA-REVIEW v1", unicode_job["final"]["note"])
        self.assertNotIn("not-a-line", task1935["jobs"])
        real_early = task1891["jobs"]["b1891"]
        self.assertEqual(real_early["final"]["reason"],
                         "f5 PR #397 merged: clusters on RS6/G63/F-150 displays, G90 tips dark metal, CI pure + Unity PASS")
        self.assertTrue(real_early["final"]["round_derived"])

    def test_tsv_is_default(self):
        result = self.run_scan("--task", "1935")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("task\tjob\t"))
        self.assertIn("1 (derived)", result.stdout)

    def test_project_states_use_one_list_call_per_state(self):
        result = self.run_scan("--project", "ParkingArcade", "--state", "merged",
                              "--state", "claimed", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["tasks_scanned"], [1891, 1935])
        self.assertEqual(data["tasks"][0]["jobs"]["b1891"]["final"]["outcome"], "accepted")
        calls = self.call_log.read_text().splitlines()
        self.assertEqual(calls, ["list|ParkingArcade|merged|500", "list|ParkingArcade|claimed|500",
                                 "1891|100|0", "1935|100|0"])

    def test_project_full_task_list_fails_closed_without_partial_scan(self):
        result = self.run_scan("--project", "TruncatedProject", "--state", "merged", "--json")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("state merged: task list may be truncated at 500 rows", result.stderr)
        self.assertEqual(self.call_log.read_text().splitlines(),
                         ["list|TruncatedProject|merged|500"])

    def test_project_list_failure_has_clean_error(self):
        self.env["PA_REVIEW_FAIL_LIST"] = "1"
        result = self.run_scan("--project", "ParkingArcade", "--state", "merged", "--json")
        self.assertEqual(result.returncode, 2)
        self.assertIn("pa-review-scan: fixture list failure", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_non_dict_list_and_comment_rows_are_tolerated(self):
        self.env["PA_REVIEW_NON_DICT"] = "1"
        result = self.run_scan("--project", "ParkingArcade", "--state", "merged", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["tasks_scanned"], [1935])
        self.assertIn("b1935", data["tasks"][0]["jobs"])

    def test_comments_are_paged_until_short_page(self):
        fixture = json.loads(Path(self.env["PA_REVIEW_FIXTURE"]).read_text())
        fixture = [{"id": index, "task_id": 1935, "author": "pa-integrator",
                    "created_at": f"2026-10-24T10:{index // 60:02d}:{index % 60:02d}Z",
                    "body": "ordinary note"} for index in range(1, 206)]
        Path(self.env["PA_REVIEW_FIXTURE"]).write_text(json.dumps(fixture))
        result = self.run_scan("--task", "1935", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.call_log.read_text().splitlines()
        self.assertEqual(calls, ["1935|100|0", "1935|100|100", "1935|100|200"])

    def test_fixture_has_real_early_examples(self):
        rows = json.loads(FIXTURE.read_text())
        bodies = [c["body"] for c in rows]
        self.assertIn("PA-REVIEW task=1935 job=b1935 outcome=accepted reason=RS6 DRL corner clean + F-150 AT tread, tester PASS, QA 0 errors", bodies)
        self.assertIn("PA-REVIEW task=1891 job=b1891 outcome=accepted reason=f5 PR #397 merged: clusters on RS6/G63/F-150 displays, G90 tips dark metal, CI pure + Unity PASS", bodies)


if __name__ == "__main__":
    unittest.main()
