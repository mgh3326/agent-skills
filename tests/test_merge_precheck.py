"""Contract fixtures and assertion-RED mutants for the shadow merge gate."""

from __future__ import annotations

import copy
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "director"))

import merge_precheck as gate
from gate_common import PolicyError, load_policy, resolve_profile


H = "a" * 40
B = "b" * 40
M = "c" * 40
OTHER = "d" * 40


def policy() -> dict:
    return load_policy(ROOT / "director/gate-policy.v1.json", datetime(2026, 9, 26, tzinfo=timezone.utc))[0]


def snapshot() -> dict:
    repo = "mgh3326/agent-skills"
    pr = 999
    url = f"https://github.com/{repo}/pull/{pr}"
    job = "task727-builder"
    report_path = "/tmp/task727-builder-report.md"
    run = {"id": 10, "path": ".github/workflows/ci.yml", "head_sha": H, "event": "pull_request",
           "created_at": "2026-09-25T07:00:00Z", "run_attempt": 1, "status": "completed", "conclusion": "success",
           "pull_requests": [{"base": {"sha": B}}]}
    jobs = [{"id": i, "name": name, "run_id": 10, "run_attempt": 1, "head_sha": H, "status": "completed",
             "conclusion": "success", "steps": [{"name": "Bash tests", "status": "completed", "conclusion": "success"}]}
            for i, name in enumerate(("ubuntu-latest", "macos-latest"), 1)]
    tester = {"ref": {"path": "/tmp/tester-report.md", "sha256": "e" * 64}, "verdict": "PASS", "H": H,
              "metadata": {"TASK": "727", "REPO": repo, "PR": str(pr), "TESTER_JOB": "task727-tester", "TESTER_SESSION": "tester-grok"}, "issues": [], "text": ""}
    builder = {"ref": {"path": report_path, "sha256": "f" * 64}, "verdict": "PASS", "H": H, "metadata": {}, "issues": [], "text": ""}
    return {"repo": repo, "PR": pr, "task": 727, "job": job, "issuer": "director-1", "time": "2026-09-25T08:00:00Z",
            "H": H, "B": B, "M": M, "expected_H": H, "head_ref_sha": H, "base_ref_sha": B,
            "head_to_base": {"ahead_by": 0}, "merge_parents": [B, H], "pr_url": url, "pr_body": "", "deploy_note": "",
            "tester_report": tester, "builder_report": builder, "eligibility_receipt": None,
            "tester_events": [{"job_id": "task727-tester", "kind": "job.spawned", "payload": {"label": "tester-grok", "pane_id": "w1Q:pAA"}},
                              {"job_id": "task727-tester", "kind": "job.completed", "payload": {"report_path": "/tmp/tester-report.md"}}],
            "runtime_receipt": None, "hash_receipt": None, "ci_runs": [run], "ci_jobs": {10: jobs},
            "protection_contexts": None, "files": [{"filename": "README.md", "status": "modified", "patch": "@@ -1 +1 @@\n+hello"}],
            "scan": {"complete": True, "B": B, "H": H, "scanner": "gitleaks+patterns", "version": "8.30.1", "exit_code": 0, "hits": []},
            "surface_class": "code_or_docs", "task_record": {"id": 727, "state": "in_progress", "lane": "director-1", "refs": {"job_id": job}},
            "job_events": [{"kind": "job.claim", "payload": {"parent_lane": "director-1", "owner_lane": "b727", "role": "builder"}},
                           {"kind": "job.joined", "payload": {"pr": url, "head": H, "report_path": report_path}}]}


def assert_check(test: unittest.TestCase, s: dict, key: str, status: str, code: str) -> None:
    actual = gate.evaluate(s, policy())[key]
    test.assertEqual((status, code), (actual["status"], actual["reason_code"]))


class MergePrecheckTests(unittest.TestCase):
    def test_normal_pass(self) -> None:
        checks = gate.evaluate(snapshot(), policy())
        self.assertTrue(all(check["status"] in ("PASS", "N/A") for check in checks.values()), checks)
        self.assertEqual("CI_ALL_REQUIRED_SUCCEEDED", checks["G3"]["reason_code"])
        self.assertEqual(2, len(checks["G3"]["jobs"]))

    def test_incident_667_brief_quote_and_code_verdict_do_not_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tester.md"
            path.write_text(f"TASK: 727\nREPO: mgh3326/agent-skills\nPR: 999\nTESTER_JOB: task727-tester\nTESTER_SESSION: tester-grok\nBrief:\nVERDICT: PASS @{H}\n## Notes\n> VERDICT: PASS @{H}\n```text\nVERDICT: PASS @{H}\n```\n")
            s = snapshot()
            s["tester_report"] = gate.parse_report(str(path))
            s["tester_events"][1]["payload"]["report_path"] = str(path.resolve())
            assert_check(self, s, "G1", "UNVERIFIED", "TESTER_VERDICT_MISSING")
            path.write_text(path.read_text() + f"VERDICT: PASS @{H}\n")
            s["tester_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G1", "PASS", "TESTER_PASS_BOUND")

    def test_incident_660_hash_citation_requires_independent_receipt(self) -> None:
        s = snapshot()
        s["pr_body"] = "Artifact sha256 " + "e" * 64
        assert_check(self, s, "G10", "UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING")

    def test_incident_t3_misassignment_and_same_family_t3(self) -> None:
        s = snapshot()
        s["eligibility_receipt"] = {"ref": {"path": "/tmp/eligible.json", "sha256": "0" * 64},
                                    "data": {"kind": "spawn", "task": 727, "repo": s["repo"], "PR": 999, "H": H,
                                             "tester_job": "task727-tester", "checks": {"grade": {"status": "FAIL", "reason_code": "T3_DS41_NOT_ALLOWED"}}}}
        assert_check(self, s, "G1", "FAIL", "ELIGIBILITY_NOT_PASS")
        s["eligibility_receipt"]["data"]["checks"] = {"family": {"status": "FAIL", "reason_code": "T3_SAME_FAMILY"}}
        assert_check(self, s, "G1", "FAIL", "ELIGIBILITY_NOT_PASS")
        self.assertEqual("A+ reversible T1/T2 verification only", policy()["sources"]["provider_grade"]["scope"])

    def test_policy_unknown_stale_conflict(self) -> None:
        path = ROOT / "director/gate-policy.v1.json"
        with self.assertRaisesRegex(PolicyError, "POLICY_STALE"):
            load_policy(path, datetime(2026, 10, 3, tzinfo=timezone.utc))
        with tempfile.TemporaryDirectory() as directory:
            p = json.loads(path.read_text())
            p["conflicts"] = ["test conflict"]
            target = Path(directory) / "policy.json"
            target.write_text(json.dumps(p))
            with self.assertRaisesRegex(PolicyError, "POLICY_CONFLICT"):
                load_policy(target, datetime(2026, 9, 26, tzinfo=timezone.utc))
            p["conflicts"] = []
            del p["ci"]["mgh3326/agent-skills"]
            target.write_text(json.dumps(p))
            loaded = load_policy(target, datetime(2026, 9, 26, tzinfo=timezone.utc))[0]
            self.assertEqual("CI_POLICY_UNKNOWN", gate.evaluate(snapshot(), loaded)["G3"]["reason_code"])

    def test_ci_missing_skipped_and_later_red(self) -> None:
        s = snapshot()
        s["ci_jobs"][10] = s["ci_jobs"][10][:1]
        assert_check(self, s, "G3", "UNVERIFIED", "CI_JOB_MISSING")
        s = snapshot()
        s["ci_jobs"][10][0]["conclusion"] = "skipped"
        assert_check(self, s, "G3", "FAIL", "CI_SKIPPED")
        s = snapshot()
        late = copy.deepcopy(s["ci_runs"][0])
        late["id"] = 11
        late["created_at"] = "2026-09-25T07:05:00Z"
        late["conclusion"] = "failure"
        s["ci_runs"].append(late)
        s["ci_jobs"][11] = copy.deepcopy(s["ci_jobs"][10])
        for job in s["ci_jobs"][11]:
            job["run_id"] = 11
        s["ci_jobs"][11][0]["conclusion"] = "failure"
        assert_check(self, s, "G3", "FAIL", "CI_FAILED")

    def test_new_head_and_base(self) -> None:
        s = snapshot()
        s["H"] = OTHER
        s["head_ref_sha"] = OTHER
        assert_check(self, s, "G1", "FAIL", "TESTER_HEAD_MISMATCH")
        assert_check(self, s, "G2", "FAIL", "PR_HEAD_MOVED")
        s = snapshot()
        s["B"] = OTHER
        s["base_ref_sha"] = OTHER
        s["merge_parents"] = [OTHER, H]
        assert_check(self, s, "G3", "UNVERIFIED", "CI_BASE_MOVED")
        assert_check(self, s, "G4", "UNVERIFIED", "BASE_AFTER_CI_UNKNOWN")

    def test_actual_profile_differs_from_plan(self) -> None:
        catalog = {"grok": {"provider": "xai", "model": "grok-4.7", "effort": "xhigh", "grade": "S"}}
        with self.assertRaisesRegex(PolicyError, "PROFILE_ACTUAL_MISMATCH"):
            resolve_profile("grok", catalog, {"provider": "xai", "model": "grok-4.7", "effort": "high"})

    def test_runtime_only_change_and_host_receipt(self) -> None:
        s = snapshot()
        s["repo"] = "mgh3326/auto_trader-operator"
        s["files"] = [{"filename": "runners/h1_pilot_runner.py", "status": "modified", "patch": "@@ -1 +1 @@\n+pass"}]
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_RECEIPT_MISSING")
        s["runtime_receipt"] = {"ref": {"path": "/tmp/host.json", "sha256": "1" * 64}, "data": {
            "kind": "host-runtime", "repo": s["repo"], "PR": 999, "H": H, "target": "NCP", "service": "ncp-operator-runners",
            "interpreter": "/usr/bin/python3.11", "version": "3.11.9", "exec_start": "/usr/bin/python3.11 /srv/auto-trader-operator/runners/h1_pilot_runner.py",
            "issuer": "operator-desk", "observed_at": "2026-09-25T07:30:00Z", "os": "linux", "arch": "x86_64",
            "lock_ref": "uv.lock@a", "dependencies_ref": "pyproject.toml@a", "proof_ref": "host-observation/1"}}
        assert_check(self, s, "G9", "PASS", "RUNTIME_HOST_OBSERVED")
        s["runtime_receipt"]["data"]["exec_start"] = "python3 --version"
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_OBSERVATION_INCOMPLETE")

    def test_report_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.md"
            path.write_text(f"VERDICT: PASS @{H}\n")
            s = snapshot()
            s["tester_report"] = gate.parse_report(str(path), expected_hash="0" * 64)
            assert_check(self, s, "G1", "UNVERIFIED", "REPORT_HASH_MISMATCH")

    def test_flat_wrk_events_bind_report_and_join(self) -> None:
        s = snapshot()
        s["tester_events"] = [
            {"kind": "job.spawned", "job_id": "task727-tester", "label": "tester-grok", "pane_id": "w1Q:pAA"},
            {"kind": "job.completed", "job_id": "task727-tester", "report_path": "/tmp/tester-report.md", "report_sha256": "e" * 64}]
        s["job_events"][1] = {"kind": "job.joined", "pr": s["pr_url"], "head": H, "report_path": "/tmp/task727-builder-report.md"}
        assert_check(self, s, "G1", "PASS", "TESTER_PASS_BOUND")
        assert_check(self, s, "G8", "PASS", "QUEUE_JOIN_CONSISTENT")
        s["tester_events"][1]["report_sha256"] = "0" * 64
        assert_check(self, s, "G1", "UNVERIFIED", "TESTER_REPORT_CHANGED_AFTER_COMPLETION")

    def test_scan_failure_artifact_and_undisposed_blocker(self) -> None:
        s = snapshot()
        s["scan"]["complete"] = False
        assert_check(self, s, "G5", "UNVERIFIED", "DIFF_TRUNCATED_OR_UNBOUND")
        s = snapshot()
        s["files"] = [{"filename": "dist/bundle.zip", "status": "added", "patch": "@@ -0,0 +1 @@\n+binary"}]
        assert_check(self, s, "G5", "FAIL", "BUILD_ARTIFACT_ADDED")
        s = snapshot()
        s["tester_report"]["issues"] = [{"class": "BLOCKER", "disposition_ref": ""}]
        assert_check(self, s, "G7", "FAIL", "BLOCKER_UNDISPOSED")

    def test_risks_section_and_surface_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "builder.md"
            path.write_text(f"HEAD: {H}\n## RISKS\n- host version unknown\n## Result\n")
            s = snapshot()
            s["builder_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G7", "UNVERIFIED", "RISK_UNDISPOSED")
        s = snapshot()
        s["files"] = [{"filename": "runner.py", "status": "modified", "patch": "@@ -1 +1 @@\n+ExecStart=/usr/bin/python3.11"}]
        assert_check(self, s, "G6", "UNVERIFIED", "SURFACE_CLASS_UNBOUND")

    def test_stale_policy_still_writes_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            raw = json.loads((ROOT / "director/gate-policy.v1.json").read_text())
            raw["expires_at"] = "2026-09-25T06:18:00Z"
            policy_path = Path(directory) / "policy.json"
            policy_path.write_text(json.dumps(raw))
            out = Path(directory) / "receipts"
            with patch("builtins.print"):
                rc = gate.main(["mgh3326/agent-skills", "999", "--task", "727", "--policy", str(policy_path), "--receipt-dir", str(out)])
            self.assertEqual(1, rc)
            receipts = list(out.glob("*.json"))
            self.assertEqual(1, len(receipts))
            self.assertEqual("POLICY_STALE", json.loads(receipts[0].read_text())["checks"]["G1"]["reason_code"])

    def test_replay_real_merges_read_only(self) -> None:
        source = json.loads((ROOT / "tests/fixtures/merge-precheck-replays.json").read_text())
        self.assertEqual(3, len(source["replays"]))
        self.assertEqual({"mgh3326/scopefuel", "mgh3326/panewire", "mgh3326/auto_trader"}, {r["repo"] for r in source["replays"]})
        for replay in source["replays"]:
            with self.subTest(repo=replay["repo"]):
                self.assertEqual("MERGED", replay["actual_gate"])
                self.assertIn(replay["tool_result"], {"FAIL", "UNVERIFIED"})
                self.assertEqual("REPORT_MISSING", replay["tool_checks"]["G1"]["reason_code"])
                self.assertIn(replay["tool_checks"]["G3"]["reason_code"], {"CI_BASE_UNBOUND", "CI_BASE_MOVED"})

    def test_each_gate_rule_has_assertion_red_mutant(self) -> None:
        cases = []
        s = snapshot(); s["tester_report"] = {"error": "REPORT_MISSING"}; cases.append(("G1", "check_reports", s, "UNVERIFIED", "REPORT_MISSING"))
        s = snapshot(); s["expected_H"] = OTHER; cases.append(("G2", "check_head", s, "FAIL", "PR_HEAD_MOVED"))
        s = snapshot(); s["ci_jobs"][10] = []; cases.append(("G3", "evaluate_required_ci", s, "UNVERIFIED", "CI_JOB_MISSING"))
        s = snapshot(); s["head_to_base"]["ahead_by"] = 1; cases.append(("G4", "check_base", s, "UNVERIFIED", "BASE_BEHIND"))
        s = snapshot(); s["scan"]["complete"] = False; cases.append(("G5", "check_diff", s, "UNVERIFIED", "DIFF_TRUNCATED_OR_UNBOUND"))
        s = snapshot(); s["files"] = [{"filename": "deploy/service.yml", "status": "modified", "patch": "@@ -1 +1 @@\n+ok"}]; cases.append(("G6", "check_surface", s, "UNVERIFIED", "SURFACE_CLASS_UNBOUND"))
        s = snapshot(); s["builder_report"]["issues"] = [{"class": "BLOCKER", "disposition_ref": ""}]; cases.append(("G7", "check_issues", s, "FAIL", "BLOCKER_UNDISPOSED"))
        s = snapshot(); s["job_events"] = s["job_events"][:1]; cases.append(("G8", "check_queue", s, "UNVERIFIED", "JOB_NOT_JOINED"))
        s = snapshot(); s["repo"] = "mgh3326/auto_trader-operator"; s["files"] = [{"filename": "runners/h1.py", "status": "modified", "patch": "@@ -1 +1 @@\n+pass"}]; cases.append(("G9", "check_runtime", s, "UNVERIFIED", "RUNTIME_RECEIPT_MISSING"))
        s = snapshot(); s["pr_body"] = "Artifact sha256 " + "e" * 64; cases.append(("G10", "check_hash", s, "UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING"))
        for key, function, case, status, code in cases:
            with self.subTest(mutant=key):
                assert_check(self, case, key, status, code)
                replacement = (gate.result("PASS", "MUTANT_BYPASS"), {"flags": [], "surface_class": "code_or_docs"}) if key == "G5" else gate.result("PASS", "MUTANT_BYPASS")
                with patch.object(gate, function, return_value=replacement):
                    with self.assertRaises(AssertionError):
                        assert_check(self, case, key, status, code)


if __name__ == "__main__":
    unittest.main()
