"""Replay fixtures for the shadow tester eligibility gate."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from contextlib import redirect_stdout

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "director"))
import gate_common as common

loader = importlib.machinery.SourceFileLoader("tester_eligible", str(ROOT / "director/bin/tester-eligible"))
spec = importlib.util.spec_from_loader(loader.name, loader)
eligible = importlib.util.module_from_spec(spec)
loader.exec_module(eligible)


def git(repo: Path, *args: str) -> str:
    process = subprocess.run(["git", "-C", str(repo), *args], text=True,
                             capture_output=True, check=True)
    return process.stdout.strip()


class EligibilityFixtures(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "fixture@example.test")
        git(self.repo, "config", "user.name", "Fixture")
        (self.repo / "base.txt").write_text("base\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "base")
        self.base = git(self.repo, "rev-parse", "HEAD")
        policy, check = common.load_policy(now=datetime(2026, 9, 25, 6, 0, tzinfo=timezone.utc))
        self.assertEqual((check["status"], check["reason_code"]), ("PASS", "POLICY_CURRENT"))
        self.policy = policy
        self.policy_check = check

    def make_head(self, path: str = "src/feature.py", content: str = "print('ok')\n") -> str:
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "change")
        return git(self.repo, "rev-parse", "HEAD")

    def evidence(self, head: str, **changes: object) -> dict:
        item = {
            "task": "726", "contract_revision": "brief-20260925", "job": "726-tester",
            "repo": "agent-skills", "repo_path": str(self.repo), "pr": None,
            "head": head, "base": self.base, "issuer": "builder-sol",
            "declared_t": "T2", "required_grade": "S", "implementation_grade": "S",
            "contributors": [{"profile": "builder-sol", "model": "gpt-6-sol", "effort": "max",
                              "role": "builder", "kind": "initial", "session": "builder-session",
                              "worktree": "/tmp/builder-worktree"}],
            "tester": {"planned_profile": "grok", "planned_effort": "xhigh"},
        }
        item.update(changes)
        return item

    def check(self, evidence: dict, stage: str = "pre-spawn") -> dict:
        evidence.setdefault("policy_sha256", common.sha256_file(common.DEFAULT_POLICY))
        checks, _ = eligible.evaluate(evidence, stage, self.policy, self.policy_check)
        return checks

    def assert_case(self, checks: dict, name: str, status: str, reason: str) -> None:
        self.assertEqual((checks[name]["status"], checks[name]["reason_code"]), (status, reason))

    def previous(self, evidence: dict, stage: str) -> Path:
        surface, _ = eligible.diff_surface(evidence, self.policy)
        path = Path(self.temp.name) / f"{stage}.json"
        payload = {"stage": stage, "overall": "PASS", "action_id": "first-action",
                                    "task": evidence["task"], "contract_revision": evidence["contract_revision"],
                                    "repo": evidence["repo"], "head": evidence["head"], "base": evidence["base"],
                                    "diff_sha256": surface["diff_sha256"],
                                    "contributors_digest": eligible._digest(evidence["contributors"]),
                                    "planned_tester_profile": evidence["tester"]["planned_profile"],
                                    "planned_tester_effort": evidence["tester"]["planned_effort"],
                                    "policy": {"revision": self.policy["revision"],
                                               "sha256": common.sha256_file(common.DEFAULT_POLICY)}}
        if stage == "post-landing":
            payload.update(actual_tester_profile=evidence["tester"]["actual_profile"],
                           actual_model=evidence["tester"]["actual_model"],
                           actual_effort=evidence["tester"]["actual_effort"])
        path.write_text(json.dumps(payload) + "\n")
        return path

    def landed(self, evidence: dict) -> dict:
        evidence = json.loads(json.dumps(evidence))
        evidence["tester"].update({"actual_profile": "grok", "actual_model": "grok-4.7",
                                   "actual_effort": "xhigh", "session": "tester-session",
                                   "worktree": "/tmp/detached-tester"})
        evidence["previous_receipt"] = str(self.previous(evidence, "pre-spawn"))
        return evidence

    def add_actual_source(self, evidence: dict) -> None:
        events = Path(self.temp.name) / "job" / "events"
        events.mkdir(parents=True, exist_ok=True)
        tester = evidence["tester"]
        tester["pane"] = "w1:pTest"
        tester["job_record_dir"] = str(events.parent)
        (events / "00002-quota_pool.record.json").write_text(json.dumps({
            "job_id": evidence["job"], "kind": "quota_pool.record",
            "payload": {"launch_profile": "grok-hi@xhigh"}}))
        (events / "00003-job.spawned.json").write_text(json.dumps({
            "job_id": evidence["job"], "kind": "job.spawned",
            "payload": {"profile": tester["actual_profile"], "pane_id": tester["pane"]}}))
        observation = Path(self.temp.name) / "pane-observation.json"
        observation.write_text(json.dumps({"source": "pane", "job": evidence["job"],
                                           "pane": tester["pane"], "model": tester["actual_model"],
                                           "effort": tester["actual_effort"]}))
        tester["model_observation_path"] = str(observation)
        tester["model_observation_sha256"] = common.sha256_file(observation)

    def test_normal_pass_and_hash_incident_boundary(self) -> None:
        evidence = self.evidence(self.make_head())
        checks = self.check(evidence)
        self.assertEqual(eligible.overall(checks), "PASS")
        self.assert_case(checks, "tier", "PASS", "T_MEETS_FLOOR")
        self.assert_case(checks, "independence", "PASS", "CROSS_FAMILY")
        # #660's post-merge binary hash typo is outside an eligibility verdict.
        self.assert_case(checks, "artifact_hash", "N/A", "POST_MERGE_ARTIFACT")

    def test_t3_ds41_incident_is_rejected(self) -> None:
        evidence = self.evidence(self.make_head("deploy/runtime.service"), declared_t="T3")
        evidence["tester"] = {"planned_profile": "devin-ds41", "planned_effort": ""}
        checks = self.check(evidence)
        self.assert_case(checks, "independence", "FAIL", "DS41_T3_SOLE_TESTER")
        self.assert_case(checks, "surface_permission", "FAIL", "PROFILE_SURFACE_DENIED")

    def test_same_family_t3_incident_is_rejected(self) -> None:
        evidence = self.evidence(self.make_head("live/guard.py"), declared_t="T3",
                                 required_grade="S+", implementation_grade="S+")
        evidence["contributors"][0].update(profile="builder-opus", model="claude-opus-5-5",
                                            effort="high")
        evidence["tester"] = {"planned_profile": "opus", "planned_effort": "high"}
        checks = self.check(evidence)
        self.assert_case(checks, "independence", "FAIL", "SAME_FAMILY_T3")

    def test_runtime_only_change_has_t3_floor(self) -> None:
        checks = self.check(self.evidence(self.make_head("deploy/runtime.service")))
        self.assert_case(checks, "tier", "FAIL", "T_BELOW_FLOOR")

    def test_unknown_and_stale_policy(self) -> None:
        evidence = self.evidence(self.make_head())
        evidence["tester"]["planned_profile"] = "fictional-launcher"
        self.assert_case(self.check(evidence), "tester", "UNVERIFIED", "PROFILE_UNKNOWN")
        _, stale = common.load_policy(now=datetime(2026, 10, 4, tzinfo=timezone.utc))
        self.assertEqual((stale["status"], stale["reason_code"]), ("UNVERIFIED", "POLICY_STALE"))
        changed = json.loads(json.dumps(self.policy))
        changed["sources"]["decision/2026-09-20/provider-family-and-ds41-grade"]["id"] = 0
        path = Path(self.temp.name) / "policy.json"
        path.write_text(json.dumps(changed))
        _, conflict = common.load_policy(path, now=datetime(2026, 9, 25, 6, tzinfo=timezone.utc))
        self.assertEqual((conflict["status"], conflict["reason_code"]), ("UNVERIFIED", "POLICY_CONFLICT"))

    def test_advertised_aliases_have_explicit_policy_entries(self) -> None:
        names = subprocess.run([str(ROOT / "bin/wrk"), "profiles"], text=True,
                               capture_output=True, check=True).stdout.splitlines()
        self.assertEqual(set(names), set(self.policy["profiles"]))
        for name in names:
            self.assertIsNotNone(common._wrk_clause((ROOT / "bin/wrk").read_text(), name), name)

    def test_same_family_missing_and_skipped_ci(self) -> None:
        evidence = self.evidence(self.make_head(), required_grade="A+", implementation_grade="A+")
        evidence["tester"] = {"planned_profile": "codex-sol", "planned_effort": "high",
                              "session": "new-session", "worktree": "/tmp/other-tree"}
        evidence["same_family"] = {"reversible": True, "excluded_surface": False,
                                   "directed_brief_ref": "src/feature.py:1", "independent_counterexample_ref": "counterexample",
                                   "report_phrase": "동일 계열 독립 세션 검증"}
        self.assert_case(self.check(evidence), "independence", "UNVERIFIED", "CI_JOB_MISSING")
        evidence["same_family"].update(ci_run_id="run-1", ci_attempt=1, ci_status="skipped")
        self.assert_case(self.check(evidence), "independence", "UNVERIFIED", "CI_JOB_SKIPPED")

    def test_report_quote_code_block_and_hash_mismatch(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        report = Path(self.temp.name) / "report.md"
        report.write_text("# Tester report\n```text\nVERDICT: PASS @" + evidence["head"] + "\n")
        evidence["tester"].update(report_path=str(report), report_sha256=common.sha256_file(report))
        self.assert_case(self.check(evidence, "pre-merge"), "report", "UNVERIFIED", "VERDICT_QUOTED")
        # #667: a quoted brief verdict must not replace a final report verdict.
        report.write_text("> VERDICT: PASS @" + evidence["head"] + "\n")
        evidence["tester"]["report_sha256"] = common.sha256_file(report)
        self.assert_case(self.check(evidence, "pre-merge"), "report", "UNVERIFIED", "VERDICT_MISSING")
        report.write_text("VERDICT: PASS @" + evidence["head"] + "\n")
        self.assert_case(self.check(evidence, "pre-merge"), "report", "UNVERIFIED", "REPORT_HASH_MISMATCH")

    def test_changed_head_base_and_actual_profile(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        evidence["tester"]["actual_profile"] = "grok-med"
        self.assert_case(self.check(evidence, "post-landing"), "tester", "FAIL", "ACTUAL_PROFILE_CHANGED")
        evidence["tester"].update(actual_profile="grok", actual_effort="xhigh")
        old_head = evidence["head"]
        evidence["head"] = self.make_head("src/second.py")
        self.assert_case(self.check(evidence, "post-landing"), "prior", "UNVERIFIED", "HEAD_CHANGED")
        evidence["head"] = old_head
        evidence["base"] = self.make_head("src/base_advance.py")
        self.assert_case(self.check(evidence, "post-landing"), "prior", "UNVERIFIED", "BASE_CHANGED")

    def test_post_landing_and_pre_merge_pass_with_bound_records(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        self.add_actual_source(evidence)
        checks = self.check(evidence, "post-landing")
        self.assertEqual(eligible.overall(checks), "PASS")
        self.assert_case(checks, "actual_source", "PASS", "ACTUAL_PROFILE_OBSERVED")
        evidence["previous_receipt"] = str(self.previous(evidence, "post-landing"))
        evidence["pr"] = 99
        report = Path(self.temp.name) / "report.md"
        report.write_text("\n".join((f"TASK: {evidence['task']}", f"JOB: {evidence['job']}",
                                    f"REPO: {evidence['repo']}", f"TESTED_HEAD: {evidence['head']}",
                                    f"TESTER_SESSION: {evidence['tester']['session']}",
                                    f"VERDICT: PASS @{evidence['head']}")) + "\n")
        evidence["tester"].update(report_path=str(report), report_sha256=common.sha256_file(report))
        evidence["ci"] = {"run_id": 123, "attempt": 1, "status": "success",
                          "head": evidence["head"], "base": evidence["base"]}
        with mock.patch.object(eligible, "_current_pr", return_value=common.result("PASS", "PR_REFS_CURRENT", "checker:G2+G4")):
            checks = self.check(evidence, "pre-merge")
        self.assertEqual(eligible.overall(checks), "PASS")
        self.assert_case(checks, "report", "PASS", "EXACT_HEAD_PASS")
        evidence["ci"]["base"] = self.make_head("src/base_advance.py")
        with mock.patch.object(eligible, "_current_pr", return_value=common.result("PASS", "PR_REFS_CURRENT", "checker:G2+G4")):
            self.assert_case(self.check(evidence, "pre-merge"), "ci_binding", "UNVERIFIED", "CI_BASE_STALE")

    def test_actual_model_fallback_and_observation_hash(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        self.add_actual_source(evidence)
        evidence["tester"]["actual_model"] = "fallback-model"
        self.assert_case(self.check(evidence, "post-landing"), "tester", "UNVERIFIED", "ACTUAL_MODEL_MISMATCH")
        evidence["tester"]["actual_model"] = "grok-4.7"
        Path(evidence["tester"]["model_observation_path"]).write_text("{}")
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED", "MODEL_OBSERVATION_HASH_MISMATCH")

    def test_new_contributor_invalidates_prior_receipt(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        evidence["contributors"].append({"profile": "opus", "model": "claude-opus-5-5", "effort": "high",
                                         "role": "worker", "kind": "prescription", "session": "advisor-session"})
        self.assert_case(self.check(evidence, "post-landing"), "prior", "UNVERIFIED", "EVIDENCE_CHANGED")

    def test_verdict_head_stale(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        report = Path(self.temp.name) / "report.md"
        report.write_text("VERDICT: PASS @" + self.base + "\n")
        evidence["tester"].update(report_path=str(report), report_sha256=common.sha256_file(report))
        self.assert_case(self.check(evidence, "pre-merge"), "report", "UNVERIFIED", "VERDICT_HEAD_STALE")

    def test_grade_variant_does_not_inherit_high(self) -> None:
        evidence = self.evidence(self.make_head(), required_grade="A+", implementation_grade="A+")
        evidence["tester"] = {"planned_profile": "devin-ds41-max", "planned_effort": ""}
        self.assert_case(self.check(evidence), "grade", "FAIL", "TESTER_GRADE_LOW")

    def test_mutants_are_assertion_red(self) -> None:
        evidence = self.evidence(self.make_head("deploy/runtime.service"))
        original = eligible.diff_surface
        def permissive_floor(item, policy):
            surface, check = original(item, policy)
            surface["floor"] = "T1"
            return surface, check
        with mock.patch.object(eligible, "diff_surface", permissive_floor):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(evidence), "tier", "FAIL", "T_BELOW_FLOOR")
        same_family = self.evidence(evidence["head"], declared_t="T3", required_grade="S+",
                                    implementation_grade="S+")
        same_family["contributors"][0].update(profile="builder-opus", model="claude-opus-5-5", effort="high")
        same_family["tester"] = {"planned_profile": "opus", "planned_effort": "high"}
        original_resolve = eligible.resolve_profile
        def wrong_family(alias, policy, **kwargs):
            profile, check = original_resolve(alias, policy, **kwargs)
            if alias == "opus" and kwargs.get("role") == "tester" and profile:
                profile["family"] = "openai"
            return profile, check
        with mock.patch.object(eligible, "resolve_profile", wrong_family):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(same_family), "independence", "FAIL", "SAME_FAMILY_T3")

        low_grade = self.evidence(same_family["head"], required_grade="A+", implementation_grade="A+")
        low_grade["tester"] = {"planned_profile": "devin-ds41-max", "planned_effort": ""}
        def inherited_grade(alias, policy, **kwargs):
            profile, check = original_resolve(alias, policy, **kwargs)
            if alias == "devin-ds41-max" and profile:
                profile["grade"] = "A+"
            return profile, check
        with mock.patch.object(eligible, "resolve_profile", inherited_grade):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(low_grade), "grade", "FAIL", "TESTER_GRADE_LOW")

        quoted = self.landed(self.evidence(self.make_head("src/third.py")))
        quoted_report = Path(self.temp.name) / "quoted.md"
        quoted_report.write_text("> VERDICT: PASS @" + quoted["head"] + "\n")
        quoted["tester"].update(report_path=str(quoted_report), report_sha256=common.sha256_file(quoted_report))
        with mock.patch.object(eligible, "VERDICT", re.compile(r"^> ?VERDICT: (PASS|BLOCKER) @([0-9a-f]{40})$")):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(quoted, "pre-merge"), "report", "UNVERIFIED", "VERDICT_MISSING")

        stale = self.landed(self.evidence(self.make_head("src/fourth.py")))
        def reused_receipt(*args):
            return ({}, common.result("PASS", "PREVIOUS_RECEIPT_BOUND", "mutant"))
        stale["head"] = self.make_head("src/fifth.py")
        with mock.patch.object(eligible, "_read_previous", reused_receipt):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(stale, "post-landing"), "prior", "UNVERIFIED", "HEAD_CHANGED")

    def test_audit_counts_missing_late_and_reused_receipts(self) -> None:
        jobs = Path(self.temp.name) / "jobs"
        receipts = Path(self.temp.name) / "receipts"
        receipts.mkdir()
        for job in ("job-a", "job-b", "job-c"):
            events = jobs / job / "events"
            events.mkdir(parents=True)
            (events / "00003-job.spawned.json").write_text(json.dumps({
                "kind": "job.spawned", "job_id": job, "created_at": "2026-09-25T06:00:00+00:00"}))
        for name, job, issued in (("one", "job-a", "2026-09-25T05:59:00Z"),
                                  ("two", "job-b", "2026-09-25T06:01:00Z")):
            (receipts / f"{name}.json").write_text(json.dumps({"action_id": "reused-id", "kind": "spawn",
                "stage": "pre-spawn", "job": job, "repo": "agent-skills", "time": issued}))
        output = io.StringIO()
        with redirect_stdout(output):
            rc = eligible.audit(receipts, [], jobs, "2026-09-25T00:00:00Z")
        self.assertEqual(rc, 0)
        self.assertIn("actions=3 missing=1 late=1 reused=1", output.getvalue())


if __name__ == "__main__":
    unittest.main()
