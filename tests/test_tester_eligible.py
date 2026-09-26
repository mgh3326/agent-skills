"""Replay fixtures for the shadow tester eligibility gate."""

from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
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
        git(self.repo, "remote", "add", "origin", "https://github.com/fixture/agent-skills.git")
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
        with mock.patch.object(eligible, "_read_pane", return_value=evidence.get("_pane_snapshot")):
            checks, _ = eligible.evaluate(evidence, stage, self.policy, self.policy_check)
        return checks

    def assert_case(self, checks: dict, name: str, status: str, reason: str) -> None:
        self.assertEqual((checks[name]["status"], checks[name]["reason_code"]), (status, reason))

    def previous(self, evidence: dict, stage: str) -> Path:
        surface, _ = eligible.diff_surface(evidence, self.policy)
        path = Path(self.temp.name) / f"{stage}.json"
        payload = {"stage": stage, "kind": "spawn", "overall": "PASS", "action_id": "first-action",
                                    "task": evidence["task"], "contract_revision": evidence["contract_revision"],
                                    "job": evidence["job"], "repo": evidence["repo"],
                                    "repo_path": evidence["repo_path"], "issuer": evidence["issuer"],
                                    "pr": evidence.get("pr"), "head": evidence["head"], "base": evidence["base"],
                                    "trial_merge_tree": evidence.get("trial_merge_tree"),
                                    "declared_t": evidence["declared_t"],
                                    "required_grade": evidence["required_grade"],
                                    "implementation_grade": evidence["implementation_grade"],
                                    "split": evidence.get("split"),
                                    "diff_sha256": surface["diff_sha256"],
                                    "contributors_digest": eligible._digest(evidence["contributors"]),
                                    "planned_tester_profile": evidence["tester"]["planned_profile"],
                                    "planned_tester_effort": evidence["tester"]["planned_effort"],
                                    "policy": {"revision": self.policy["revision"],
                                               "sha256": common.sha256_file(common.DEFAULT_POLICY)}}
        if stage == "post-landing":
            payload.update(actual_tester_profile=evidence["tester"]["actual_profile"],
                           actual_model=evidence["tester"]["actual_model"],
                           actual_effort=evidence["tester"]["actual_effort"],
                           actual_tester_session=evidence["tester"]["session"],
                           actual_tester_worktree=evidence["tester"]["worktree"],
                           actual_tester_pane=evidence["tester"].get("pane"))
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
        evidence["_pane_snapshot"] = "Grok 4.7 (xhigh) · always-approve"

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

    def test_deployment_and_guard_names_in_tool_repo_have_t3_floor(self) -> None:
        for path in ("k8s/deployment.yaml", "guards.py", "docker-compose.yml"):
            with self.subTest(path=path):
                git(self.repo, "reset", "--hard", self.base)
                evidence = self.evidence(self.make_head(path), declared_t="T1")
                checks = self.check(evidence)
                self.assert_case(checks, "surface", "PASS", "SURFACE_CLASSIFIED")
                self.assertEqual(checks["surface"]["floor"], "T3")
                self.assert_case(checks, "tier", "FAIL", "T_BELOW_FLOOR")

    def test_quoted_unicode_live_path_retains_t3_floor(self) -> None:
        evidence = self.evidence(self.make_head("live/한글.py"), declared_t="T1")
        checks = self.check(evidence)
        self.assert_case(checks, "surface", "PASS", "SURFACE_CLASSIFIED")
        self.assert_case(checks, "tier", "FAIL", "T_BELOW_FLOOR")

    def test_repo_identity_and_auto_trader_nontrading_floor(self) -> None:
        strategy_head = self.make_head("strategy/runner.py")
        evidence = self.evidence(strategy_head, repo="auto_trader")
        self.assert_case(self.check(evidence), "surface", "UNVERIFIED", "REPO_ID_MISMATCH")
        git(self.repo, "remote", "set-url", "origin", "https://github.com/fixture/auto_trader.git")
        self.assert_case(self.check(evidence), "surface", "UNVERIFIED", "DIFF_UNCLASSIFIABLE")
        safe_head = self.make_head("docs/readme.md")
        evidence = self.evidence(safe_head, repo="auto_trader", base=strategy_head)
        self.assert_case(self.check(evidence), "tier", "PASS", "T_MEETS_FLOOR")
        self.assertEqual(self.check(evidence)["surface"]["floor"], "T2")
        live_head = self.make_head("mock/order.py")
        evidence = self.evidence(live_head, repo="auto_trader", base=safe_head)
        self.assert_case(self.check(evidence), "tier", "FAIL", "T_BELOW_FLOOR")

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
            spec = self.policy["profiles"][name]
            if spec.get("roles") and spec["grades"].get(spec["default_effort"]) in common.GRADES:
                _, check = common.resolve_profile(name, self.policy,
                                                  actual_effort=spec["default_effort"],
                                                  role=spec["roles"][0])
                self.assertEqual(check["status"], "PASS", name)

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

    def test_same_family_requires_exclusion_proof_and_rejects_gate_surface(self) -> None:
        evidence = self.evidence(self.make_head(), required_grade="A+", implementation_grade="A+")
        evidence["tester"] = {"planned_profile": "codex-sol", "planned_effort": "high",
                              "session": "new-session", "worktree": "/tmp/other-tree"}
        evidence["same_family"] = {"reversible": True, "qualification_ref": "scopefuel:opus-xhigh",
                                   "directed_brief_ref": "src/feature.py:1", "independent_counterexample_ref": "counterexample",
                                   "ci_run_id": 123, "ci_attempt": 1, "ci_status": "success",
                                   "report_phrase": "동일 계열 독립 세션 검증"}
        self.assert_case(self.check(evidence), "independence", "UNVERIFIED", "SAME_FAMILY_PROOF_MISSING")
        evidence["same_family"]["excluded_surface"] = False
        evidence["same_family"]["reversible"] = False
        self.assert_case(self.check(evidence), "independence", "FAIL", "SAME_FAMILY_NON_REVERSIBLE")
        evidence["same_family"]["reversible"] = True
        evidence["tester"]["session"] = "builder-session"
        self.assert_case(self.check(evidence), "independence", "FAIL", "SAME_TESTER_SESSION")
        evidence["tester"]["session"] = "new-session"
        evidence["tester"]["worktree"] = "/tmp/builder-worktree"
        self.assert_case(self.check(evidence), "independence", "FAIL", "SAME_TESTER_WORKTREE")
        evidence["tester"]["worktree"] = "/tmp/other-tree"
        evidence["tester"]["planned_effort"] = "max"
        self.assert_case(self.check(evidence), "independence", "FAIL", "SAME_GRADE_EFFORT")
        evidence["tester"]["planned_effort"] = "high"
        evidence["head"] = self.make_head("director/bin/gate-helper")
        self.assert_case(self.check(evidence), "independence", "FAIL", "SAME_FAMILY_EXCLUDED_SURFACE")
        evidence["head"] = self.make_head(".github/workflows/ci.yml")
        self.assert_case(self.check(evidence), "independence", "FAIL", "SAME_FAMILY_EXCLUDED_SURFACE")

    def test_same_family_rejects_implementation_grade_s(self) -> None:
        evidence = self.evidence(self.make_head(), required_grade="A+", implementation_grade="S")
        evidence["contributors"][0].update(profile="builder-opus", model="claude-opus-5-5",
                                           effort="xhigh")
        evidence["tester"] = {"planned_profile": "opus", "planned_effort": "high",
                              "session": "new-session", "worktree": "/tmp/other-tree"}
        evidence["same_family"] = {"reversible": True, "excluded_surface": False,
                                   "qualification_ref": "scopefuel:opus-high",
                                   "directed_brief_ref": "src/feature.py:1", "independent_counterexample_ref": "case",
                                   "ci_run_id": 123, "ci_attempt": 1, "ci_status": "success",
                                   "report_phrase": "동일 계열 독립 세션 검증"}
        self.assert_case(self.check(evidence), "independence", "FAIL", "SAME_FAMILY_GRADE_EXCLUDED")

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
        report.write_text("````text\n```\nVERDICT: PASS @" + evidence["head"] + "\n")
        evidence["tester"]["report_sha256"] = common.sha256_file(report)
        self.assert_case(self.check(evidence, "pre-merge"), "report", "UNVERIFIED", "VERDICT_QUOTED")
        report.write_text("~~~text\n```\nVERDICT: PASS @" + evidence["head"] + "\n")
        evidence["tester"]["report_sha256"] = common.sha256_file(report)
        self.assert_case(self.check(evidence, "pre-merge"), "report", "UNVERIFIED", "VERDICT_QUOTED")
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
        evidence["trial_merge_tree"] = git(self.repo, "merge-tree", "--write-tree", evidence["base"], evidence["head"])
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
                          "head": evidence["head"], "base": evidence["base"],
                          "trial_merge_tree": evidence["trial_merge_tree"]}
        live_run = {"id": 123, "run_attempt": 1, "event": "pull_request", "head_sha": evidence["head"],
                    "status": "completed", "conclusion": "success", "pull_requests": [
                        {"number": 99, "head": {"sha": evidence["head"]}, "base": {"sha": evidence["base"]}}]}
        live_jobs = {"jobs": [{"name": name, "status": "completed", "conclusion": "success"}
                              for name in ("ubuntu-latest", "macos-latest")]}
        live_check = common.result("PASS", "CI_ATTEMPT_READ", "task:723")
        with mock.patch.object(eligible, "_current_pr", return_value=common.result("PASS", "PR_REFS_CURRENT", "checker:G2+G4")), \
             mock.patch.object(eligible, "read_ci_attempt", return_value=(live_run, live_jobs, live_check)):
            checks = self.check(evidence, "pre-merge")
        self.assertEqual(eligible.overall(checks), "PASS")
        self.assert_case(checks, "report", "PASS", "EXACT_HEAD_PASS")
        with mock.patch.object(eligible, "read_ci_attempt", return_value=(live_run, {"jobs": live_jobs["jobs"][:1]}, live_check)):
            self.assert_case(self.check(evidence, "pre-merge"), "ci_binding", "UNVERIFIED", "CI_JOB_MISSING")
        missing_run = common.result("UNVERIFIED", "CI_LOOKUP_FAILED", "task:723")
        with mock.patch.object(eligible, "read_ci_attempt", return_value=(None, None, missing_run)):
            self.assert_case(self.check(evidence, "pre-merge"), "ci_binding", "UNVERIFIED", "CI_LOOKUP_FAILED")
        skipped_jobs = json.loads(json.dumps(live_jobs))
        skipped_jobs["jobs"][1]["conclusion"] = "skipped"
        with mock.patch.object(eligible, "read_ci_attempt", return_value=(live_run, skipped_jobs, live_check)):
            self.assert_case(self.check(evidence, "pre-merge"), "ci_binding", "UNVERIFIED", "CI_JOB_SKIPPED")
        stale_run = json.loads(json.dumps(live_run))
        stale_run["pull_requests"][0]["base"]["sha"] = "0" * 40
        with mock.patch.object(eligible, "read_ci_attempt", return_value=(stale_run, live_jobs, live_check)):
            self.assert_case(self.check(evidence, "pre-merge"), "ci_binding", "UNVERIFIED", "CI_BASE_STALE")
        evidence["ci"]["base"] = self.make_head("src/base_advance.py")
        with mock.patch.object(eligible, "_current_pr", return_value=common.result("PASS", "PR_REFS_CURRENT", "checker:G2+G4")), \
             mock.patch.object(eligible, "read_ci_attempt", return_value=(live_run, live_jobs, live_check)):
            self.assert_case(self.check(evidence, "pre-merge"), "ci_binding", "UNVERIFIED", "CI_BASE_STALE")

    def test_actual_model_fallback_and_observation_hash(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        self.add_actual_source(evidence)
        evidence["tester"]["actual_model"] = "fallback-model"
        self.assert_case(self.check(evidence, "post-landing"), "tester", "UNVERIFIED", "ACTUAL_MODEL_MISMATCH")
        evidence["tester"]["actual_model"] = "grok-4.7"
        Path(evidence["tester"]["model_observation_path"]).write_text("{}")
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED", "MODEL_OBSERVATION_HASH_MISMATCH")
        self.add_actual_source(evidence)
        evidence["_pane_snapshot"] = "Grok 4.6 (xhigh) · always-approve"
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED", "PANE_MODEL_UNVERIFIED")

    def test_actual_launch_family_and_latest_pane_footer(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        self.add_actual_source(evidence)
        events = Path(evidence["tester"]["job_record_dir"]) / "events"
        quota_path = events / "00002-quota_pool.record.json"
        quota = json.loads(quota_path.read_text())
        quota["payload"]["launch_profile"] = "codex-sol@xhigh"
        quota_path.write_text(json.dumps(quota))
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED",
                         "ACTUAL_LAUNCH_FAMILY_MISMATCH")
        quota["payload"]["launch_profile"] = "grok45@xhigh"
        quota_path.write_text(json.dumps(quota))
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED",
                         "ACTUAL_LAUNCH_MODEL_MISMATCH")
        quota["payload"]["launch_profile"] = "builder-grok@xhigh"
        quota_path.write_text(json.dumps(quota))
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED",
                         "ACTUAL_LAUNCH_PROFILE_DENIED")
        quota["payload"]["launch_profile"] = "grok-med@xhigh"
        quota_path.write_text(json.dumps(quota))
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED",
                         "ACTUAL_LAUNCH_PROFILE_UNVERIFIED")
        quota["payload"]["launch_profile"] = "grok@xhigh"
        quota_path.write_text(json.dumps(quota))
        evidence["_pane_snapshot"] = "Grok 4.7 (xhigh) · always-approve\nGrok 4.6 (high) · always-approve"
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED",
                         "PANE_MODEL_UNVERIFIED")
        evidence["_pane_snapshot"] = "Grok 4.6 (high) · real-footer\nnote Grok 4.7 (xhigh) · spoof"
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED",
                         "PANE_MODEL_UNVERIFIED")
        evidence["_pane_snapshot"] = "Grok 4.6 (high) · real-footer note Grok 4.7 (xhigh) · spoof"
        self.assert_case(self.check(evidence, "post-landing"), "actual_source", "UNVERIFIED",
                         "PANE_MODEL_UNVERIFIED")

    def test_pane_footer_requires_model_and_effort(self) -> None:
        self.assertTrue(eligible._pane_model_matches("Grok 4.7 (xhigh) · always-approve", "grok-4.7", "xhigh"))
        self.assertTrue(eligible._pane_model_matches("GPT-6-Sol max · worktree", "gpt-6-sol", "max"))
        self.assertFalse(eligible._pane_model_matches("Grok 4.7 (high) · always-approve", "grok-4.7", "xhigh"))
        self.assertFalse(eligible._pane_model_matches("Grok 4.6 (xhigh) · always-approve", "grok-4.7", "xhigh"))

    def test_new_contributor_invalidates_prior_receipt(self) -> None:
        evidence = self.landed(self.evidence(self.make_head()))
        evidence["contributors"].append({"profile": "opus", "model": "claude-opus-5-5", "effort": "high",
                                         "role": "worker", "kind": "prescription", "session": "advisor-session"})
        self.assert_case(self.check(evidence, "post-landing"), "prior", "UNVERIFIED", "EVIDENCE_CHANGED")

    def test_prior_receipt_replay_changes_job_pr_merge_tree_or_tester(self) -> None:
        evidence = self.landed(self.evidence(self.make_head(), pr=99, trial_merge_tree="a" * 40))
        evidence["previous_receipt"] = str(self.previous(evidence, "pre-spawn"))
        changed = json.loads(json.dumps(evidence))
        changed["job"] = "another-job"
        self.assert_case(self.check(changed, "post-landing"), "prior", "UNVERIFIED", "EVIDENCE_CHANGED")
        changed = json.loads(json.dumps(evidence))
        changed["pr"] = 100
        self.assert_case(self.check(changed, "post-landing"), "prior", "UNVERIFIED", "EVIDENCE_CHANGED")
        changed = json.loads(json.dumps(evidence))
        changed["trial_merge_tree"] = "b" * 40
        self.assert_case(self.check(changed, "post-landing"), "prior", "UNVERIFIED", "MERGE_TREE_CHANGED")
        evidence["previous_receipt"] = str(self.previous(evidence, "post-landing"))
        evidence["tester"]["session"] = "different-session"
        self.assert_case(self.check(evidence, "pre-merge"), "prior", "UNVERIFIED", "ACTUAL_TESTER_CHANGED")

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

    def test_e6_builder_grades_conflict_and_grok_model_must_match_wrk(self) -> None:
        variants = ("builder-opus-low", "builder-opus-medium", "builder-sonnet-xhigh", "builder-sonnet-max",
                    "builder-sol-high", "builder-sol-max", "builder-sol-medium", "builder-luna-max", "builder-terra-high",
                    "builder-terra-xhigh", "builder-terra-max", "builder-kimi-high", "builder-kimi-max",
                    "builder-grok-low", "builder-grok-medium", "builder-grok-xhigh")
        for alias in variants:
            spec = self.policy["profiles"][alias]
            _, check = common.resolve_profile(alias, self.policy, actual_effort=spec["default_effort"],
                                              role="builder")
            self.assertEqual((check["status"], check["reason_code"]),
                             ("UNVERIFIED", "PROFILE_GRADE_CONFLICT"), alias)
        changed = json.loads(json.dumps(self.policy))
        changed["profiles"]["grok"]["model"] = "not-the-wrk-model"
        _, check = common.resolve_profile("grok", changed, actual_effort="xhigh", role="tester")
        self.assertEqual((check["status"], check["reason_code"]), ("UNVERIFIED", "POLICY_CONFLICT"))
        changed = json.loads(json.dumps(self.policy))
        changed["profiles"]["codex-sol"]["family"] = "xai"
        _, check = common.resolve_profile("codex-sol", changed, actual_effort="max", role="tester")
        self.assertEqual((check["status"], check["reason_code"]), ("UNVERIFIED", "PROFILE_FAMILY_CONFLICT"))

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

        stale_ci = self.evidence(stale["head"])
        stale_ci["ci"] = {"run_id": 1, "attempt": 1, "status": "success",
                          "head": stale_ci["head"], "base": self.base}
        stale_ci["base"] = self.make_head("src/sixth.py")
        original_ci = eligible._ci_binding
        def accepted_old_base(item):
            altered = json.loads(json.dumps(item))
            altered["ci"]["base"] = altered["base"]
            return original_ci(altered)
        with mock.patch.object(eligible, "_ci_binding", accepted_old_base):
            with self.assertRaises(AssertionError):
                answer = eligible._ci_binding(stale_ci)
                self.assertEqual((answer["status"], answer["reason_code"]),
                                 ("UNVERIFIED", "CI_BASE_STALE"))

    def test_round_two_rule_mutants_are_assertion_red(self) -> None:
        guard = self.evidence(self.make_head("docker-compose.yml"), declared_t="T1")
        weak_policy = json.loads(json.dumps(self.policy))
        weak_policy["surface_rules"]["t3_names"] = ["Dockerfile", "*.service", "*.service.*"]
        with self.assertRaises(AssertionError):
            surface, _ = eligible.diff_surface(guard, weak_policy)
            self.assertEqual(surface["floor"], "T3")

        report_evidence = self.landed(self.evidence(self.make_head("src/fence.py")))
        report = Path(self.temp.name) / "fence-mutant.md"
        report.write_text("````text\n```\nVERDICT: PASS @" + report_evidence["head"] + "\n")
        report_evidence["tester"].update(report_path=str(report), report_sha256=common.sha256_file(report))
        with mock.patch.object(eligible, "_report", return_value=common.result("PASS", "EXACT_HEAD_PASS", "mutant")):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(report_evidence, "pre-merge"), "report", "UNVERIFIED", "VERDICT_QUOTED")

        launch_evidence = self.landed(self.evidence(self.make_head("src/launch.py")))
        self.add_actual_source(launch_evidence)
        events = Path(launch_evidence["tester"]["job_record_dir"]) / "events"
        quota_path = events / "00002-quota_pool.record.json"
        quota = json.loads(quota_path.read_text())
        quota["payload"]["launch_profile"] = "grok45@xhigh"
        quota_path.write_text(json.dumps(quota))
        with mock.patch.object(eligible, "_actual_observation",
                               return_value=common.result("PASS", "ACTUAL_PROFILE_OBSERVED", "mutant")):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(launch_evidence, "post-landing"), "actual_source",
                                 "UNVERIFIED", "ACTUAL_LAUNCH_MODEL_MISMATCH")

        same = self.evidence(self.make_head("src/same.py"), required_grade="A+", implementation_grade="S")
        same["contributors"][0].update(profile="builder-opus", model="claude-opus-5-5", effort="xhigh")
        same["tester"] = {"planned_profile": "opus", "planned_effort": "high",
                          "session": "new-session", "worktree": "/tmp/other-tree"}
        same["same_family"] = {"reversible": True, "excluded_surface": False,
                               "qualification_ref": "scopefuel:opus-high", "directed_brief_ref": "brief",
                               "independent_counterexample_ref": "case", "ci_run_id": 123,
                               "ci_attempt": 1, "ci_status": "success",
                               "report_phrase": "동일 계열 독립 세션 검증"}
        original_evaluate = eligible.evaluate
        def permissive_same_family(*args, **kwargs):
            checks, bound = original_evaluate(*args, **kwargs)
            checks["independence"] = common.result("PASS", "SAME_FAMILY_EXCEPTION_PROVEN", "mutant")
            return checks, bound
        with mock.patch.object(eligible, "evaluate", permissive_same_family):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(same), "independence", "FAIL", "SAME_FAMILY_GRADE_EXCLUDED")

    def test_audit_counts_missing_late_and_reused_receipts(self) -> None:
        jobs = Path(self.temp.name) / "jobs"
        receipts = Path(self.temp.name) / "receipts"
        receipts.mkdir()
        for job in ("job-a", "job-b", "job-c"):
            events = jobs / job / "events"
            events.mkdir(parents=True)
            (events / "00003-job.spawned.json").write_text(json.dumps({
                "kind": "job.spawned", "job_id": job, "repo": "agent-skills",
                "head": "a" * 40,
                "created_at": "2026-09-25T06:00:00+00:00"}))
        for name, job, issued in (("one", "job-a", "2026-09-25T05:59:00Z"),
                                  ("two", "job-b", "2026-09-25T06:01:00Z")):
            (receipts / f"{name}.json").write_text(json.dumps({"action_id": "reused-id", "kind": "spawn",
                "stage": "pre-spawn", "job": job, "repo": "agent-skills", "head": "a" * 40,
                "time": issued}))
        output = io.StringIO()
        with redirect_stdout(output):
            rc = eligible.audit(receipts, [], jobs, "2026-09-25T00:00:00Z")
        self.assertEqual(rc, 0)
        self.assertIn("actions=3 missing=1 late=1 reused=1", output.getvalue())

    def test_audit_does_not_match_spawn_without_head(self) -> None:
        jobs = Path(self.temp.name) / "jobs"
        job = jobs / "headless-job"
        events = job / "events"
        events.mkdir(parents=True)
        (events / "00003-job.spawned.json").write_text(json.dumps({
            "kind": "job.spawned", "job_id": "headless-job", "repo": "agent-skills",
            "created_at": "2026-09-25T06:00:00Z"}))
        receipts = Path(self.temp.name) / "receipts"
        receipts.mkdir()
        (receipts / "one.json").write_text(json.dumps({
            "action_id": "one", "kind": "spawn", "stage": "pre-spawn",
            "job": "headless-job", "repo": "agent-skills", "head": "b" * 40,
            "time": "2026-09-25T05:59:00Z"}))
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(eligible.audit(receipts, [], jobs), 0)
        self.assertIn("actions=1 missing=1 late=0 reused=0", output.getvalue())
        output = io.StringIO()
        with mock.patch.object(eligible, "_audit_head_matches", return_value=True), redirect_stdout(output):
            eligible.audit(receipts, [], jobs)
        with self.assertRaises(AssertionError):
            self.assertIn("actions=1 missing=1 late=0 reused=0", output.getvalue())
        (job / "eligibility-evidence.json").write_text(json.dumps({
            "job": "headless-job", "repo": "agent-skills", "head": "b" * 40}))
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(eligible.audit(receipts, [], jobs), 0)
        self.assertIn("actions=1 missing=0 late=0 reused=0", output.getvalue())

    def test_audit_matches_repo_slug_but_not_unknown_spawn_repo(self) -> None:
        jobs = Path(self.temp.name) / "jobs"
        events = jobs / "unknown-job" / "events"
        events.mkdir(parents=True)
        (events / "00003-job.spawned.json").write_text(json.dumps({
            "kind": "job.spawned", "job_id": "unknown-job", "created_at": "2026-09-25T06:00:00Z"}))
        receipts = Path(self.temp.name) / "receipts"
        receipts.mkdir()
        for name, kind, key, repo in (("merge", "merge", "144", "agent-skills"),
                                      ("spawn", "spawn", "unknown-job", "other-repo")):
            (receipts / f"{name}.json").write_text(json.dumps({
                "action_id": name, "kind": kind, "stage": "pre-merge" if kind == "merge" else "pre-spawn",
                "pr": int(key) if kind == "merge" else None,
                "job": key if kind == "spawn" else None,
                "head": "a" * 40 if kind == "merge" else None,
                "repo": repo, "time": "2026-09-25T05:59:00Z"}))
        gh_response = subprocess.CompletedProcess(args=[], returncode=0,
            stdout=json.dumps([{"number": 144, "headRefOid": "a" * 40,
                                "mergedAt": "2026-09-25T06:00:00Z", "url": "https://example.test/144"}]), stderr="")
        output = io.StringIO()
        with mock.patch.object(eligible.subprocess, "run", return_value=gh_response), redirect_stdout(output):
            rc = eligible.audit(receipts, ["mgh3326/agent-skills"], jobs, "2026-09-25T00:00:00Z")
        self.assertEqual(rc, 0)
        self.assertIn("actions=2 missing=1 late=0 reused=0", output.getvalue())
        merge_receipt = receipts / "merge.json"
        changed = json.loads(merge_receipt.read_text())
        changed["head"] = "b" * 40
        merge_receipt.write_text(json.dumps(changed))
        output = io.StringIO()
        with mock.patch.object(eligible.subprocess, "run", return_value=gh_response), redirect_stdout(output):
            eligible.audit(receipts, ["mgh3326/agent-skills"], jobs, "2026-09-25T00:00:00Z")
        self.assertIn("actions=2 missing=2 late=0 reused=0", output.getvalue())


class SplitFixtures(EligibilityFixtures):
    """Mixed-grade T3 split: peripheral parts must not touch the core boundary."""

    CONTRACT = "splits/733.json"
    BOUNDARY = {"paths": ["services/lease_release.py"], "symbols": ["release_lease"]}

    def setUp(self) -> None:
        super().setUp()
        self.root = self.base

    def commit(self, files: dict) -> str:
        for path, content in files.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if content is None:
                target.unlink()
            elif isinstance(content, bytes):
                target.write_bytes(content)
            else:
                target.write_text(content)
        git(self.repo, "add", "-A", ".")
        git(self.repo, "commit", "-qm", "change")
        return git(self.repo, "rev-parse", "HEAD")

    def seed(self, files: dict) -> str:
        git(self.repo, "reset", "--hard", self.root)
        self.commit(files)
        self.base = git(self.repo, "rev-parse", "HEAD")
        return self.base

    def write_contract(self, boundary: dict | str | None = None, path: str | None = None) -> str:
        """Commit a boundary contract at base so the peripheral diff cannot author it."""
        name = path or self.CONTRACT
        if boundary is None:
            boundary = self.BOUNDARY
        content = boundary if isinstance(boundary, str) else json.dumps({"boundary": boundary})
        self.commit({name: content})
        self.base = git(self.repo, "rev-parse", "HEAD")
        return name

    def split(self, **changes: object) -> dict:
        declaration = {"parent_task": "733", "parent_t": "T3", "part": "peripheral",
                       "contract_path": self.CONTRACT}
        declaration.update(changes)
        return declaration

    def release_core(self) -> None:
        self.seed({"services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n\n"
                   "def post_send_cleanup(order):\n    release_lease(order)\n",
                   "ui/dashboard.py": "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary": self.BOUNDARY})})

    def test_728_pr2_shape_touches_core_path(self) -> None:
        # #728 PR 2: a UI PR that also carried the post-send release fix.
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n",
                            "services/lease_release.py":
                            "def release_lease(order):\n    ledger.record(order)\n\n"
                            "def post_send_cleanup(order):\n    release_lease(order)\n    ledger.preserve(order)\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        checks = self.check(evidence)
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertIn("services/lease_release.py",
                      {item["path"] for item in checks["split"]["touches"]})
        self.assertEqual(eligible.overall(checks), "FAIL")

    def test_pure_rendering_change_passes_at_declared_t(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return f'<b>{row}</b>'\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        checks = self.check(evidence)
        self.assert_case(checks, "split", "PASS", "SPLIT_PERIPHERAL_CLEAN")
        self.assert_case(checks, "tier", "PASS", "T_MEETS_FLOOR")
        self.assertEqual(eligible.overall(checks), "PASS")

    def test_one_line_guard_call_in_ui_file_fails(self) -> None:
        self.write_contract({"paths": [], "symbols": ["guard_order"]})
        head = self.commit({"ui/dashboard.py":
                            "def render(row):\n    guard_order(row)\n    return str(row)\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        checks = self.check(evidence)
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertEqual(checks["split"]["touches"][0]["kind"], "call")

    def test_missing_contract_is_unverified(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n"})
        declaration = self.split()
        declaration.pop("contract_path")
        for boundary in (None, {}, {"paths": [], "symbols": []}, {"paths": "services/"},
                         self.BOUNDARY):
            with self.subTest(boundary=boundary):
                if boundary is not None:
                    declaration["boundary"] = boundary
                else:
                    declaration.pop("boundary", None)
                self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                                 "split", "UNVERIFIED", "SPLIT_BOUNDARY_MISSING")
        declaration = self.split(contract_path="splits/absent.json")
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "SPLIT_BOUNDARY_MISSING")
        declaration = self.split(part="side")
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "SPLIT_INVALID")
        declaration = self.split(parent_task="726")
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "SPLIT_INVALID")
        declaration = self.split(parent_task=["733"])
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "SPLIT_INVALID")
        declaration = self.split(parent_t="T2")
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "SPLIT_INVALID")
        declaration = self.split(part=[])
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "SPLIT_INVALID")

    def test_core_part_forces_t3_floor(self) -> None:
        self.release_core()
        head = self.commit({"services/lease_release.py":
                            "def release_lease(order):\n    ledger.record(order)\n"})
        declaration = self.split(part="core", boundary=dict(self.BOUNDARY))
        evidence = self.evidence(head, declared_t="T2", split=declaration)
        checks = self.check(evidence)
        self.assert_case(checks, "split", "PASS", "SPLIT_CORE_DECLARED")
        self.assert_case(checks, "tier", "FAIL", "T_BELOW_FLOOR")
        self.assertEqual(checks["tier"]["floor"], "T3")
        evidence = self.evidence(head, declared_t="T3", split=declaration)
        checks = self.check(evidence)
        self.assert_case(checks, "split", "PASS", "SPLIT_CORE_DECLARED")
        self.assert_case(checks, "tier", "PASS", "T_MEETS_FLOOR")

    def test_changed_call_site_into_core_symbol_fails(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py":
                            "def render(row):\n    release_lease(row)\n    return str(row)\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        checks = self.check(evidence)
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertEqual(checks["split"]["touches"][0]["kind"], "call")

    def test_removed_guard_call_also_fails(self) -> None:
        self.seed({"services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "ui/dashboard.py": "def render(row):\n    release_lease(row)\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary": self.BOUNDARY})})
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return str(row)\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        self.assert_case(self.check(evidence), "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_enclosing_symbol_body_edit_fails(self) -> None:
        self.seed({"ui/helpers.py":
                   "def check_order_guard(order):\n    return True\n\n"
                   "def label(order):\n    return order['id']\n"})
        self.write_contract({"paths": ["safety/"], "symbols": ["check_order_guard"]})
        head = self.commit({"ui/helpers.py":
                            "def check_order_guard(order):\n    return order.get('ok', True)\n\n"
                            "def label(order):\n    return order['id']\n"})
        checks = self.check(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertEqual(checks["split"]["touches"][0]["kind"], "enclosing")

    def test_indirect_getattr_and_import_detection(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py":
                            "def render(row):\n    fn = getattr(svc, 'release_lease')\n    return fn(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.release_core()
        head = self.commit({"ui/dashboard.py":
                            "import services.lease_release\n"
                            "def render(row):\n    return str(row)\n"})
        checks = self.check(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertIn("import", {touch["kind"] for touch in checks["split"]["touches"]})

    def test_alias_and_bound_name_calls_fail(self) -> None:
        self.seed({"ui/dashboard.py":
                   "from services.lease_release import release_lease as cleanup\n"
                   "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary": self.BOUNDARY})})
        head = self.commit({"ui/dashboard.py":
                            "from services.lease_release import release_lease as cleanup\n"
                            "def render(row):\n    cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.seed({"ui/dashboard.py":
                   "svc = services.lease_release\n"
                   "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary": self.BOUNDARY})})
        head = self.commit({"ui/dashboard.py":
                            "svc = services.lease_release\n"
                            "def render(row):\n    svc.release_lease(row)\n    return str(row)\n"})
        checks = self.check(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_dynamic_assembly_is_needs_classification(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py":
                            "def render(row):\n    fn = getattr(svc, 'relea' + 'se_lease')\n"
                            "    return fn(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")
        self.release_core()
        head = self.commit({"ui/dashboard.py":
                            "def render(row):\n    exec(code)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")
        self.release_core()
        head = self.commit({"ui/dashboard.py":
                            "import importlib\n"
                            "def render(row):\n    m = importlib.import_module(name)\n    return str(m)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")

    def test_malformed_split_fields_do_not_crash(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n"})
        for malformed in (self.split(part=[]),
                          self.split(part=42),
                          self.split(behaviour_checks=[{"id": "x", "result": []}]),
                          self.split(behaviour_checks=[{"id": []}]),
                          self.split(contract_path=[])):
            with self.subTest(malformed=malformed):
                checks = self.check(self.evidence(head, declared_t="T1", split=malformed))
                self.assertEqual(checks["split"]["status"], "UNVERIFIED")

    def test_removed_def_referenced_from_boundary_fails(self) -> None:
        self.seed({"services/order_flow.py":
                   "def settle(order):\n    return format_price(order['qty'])\n",
                   "ui/format.py":
                   "def format_price(qty):\n    return f'{qty:.2f}'\n\n"
                   "def pad(text):\n    return text.center(8)\n"})
        self.write_contract({"paths": ["services/"], "symbols": []})
        head = self.commit({"ui/format.py": "def pad(text):\n    return text.center(8)\n"})
        checks = self.check(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertEqual(checks["split"]["touches"][0]["kind"], "removed_ref")

    def test_contract_path_supplies_boundary_and_tamper_fails(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return f'<b>{row}</b>'\n"})
        checks = self.check(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "PASS", "SPLIT_PERIPHERAL_CLEAN")
        head = self.commit({"ui/extra.py": "print('x')\n",
                            self.CONTRACT: json.dumps({"boundary": {"paths": [], "symbols": []}})})
        checks = self.check(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertIn("contract", {item["kind"] for item in checks["split"]["touches"]})
        dot = self.split(contract_path="./splits/733.json")
        checks = self.check(self.evidence(head, declared_t="T1", split=dot))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertIn("contract", {item["kind"] for item in checks["split"]["touches"]})
        missing = self.split(contract_path="splits/absent.json")
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=missing)),
                         "split", "UNVERIFIED", "SPLIT_BOUNDARY_MISSING")

    def test_declaration_path_spellings_are_normalized(self) -> None:
        self.write_contract({"paths": ["./services/lease_release.py"], "symbols": ["release_lease"]})
        head = self.commit({"services/lease_release.py":
                            "def release_lease(order):\n    ledger.record(order)\n    ledger.x(order)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.write_contract({"paths": ["services//lease_release.py"], "symbols": ["release_lease"]})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        for bad in ("../secrets.txt", "/abs/path", "a\\b"):
            with self.subTest(bad=bad):
                self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                          split=self.split(contract_path=bad))),
                                 "split", "UNVERIFIED", "SPLIT_INVALID")

    def test_contract_conflict_and_inline_consistency(self) -> None:
        self.write_contract("{ not json")
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "UNVERIFIED", "SPLIT_BOUNDARY_MISSING")
        self.write_contract({"paths": ["services/lease_release.py", "safety/x.py"],
                             "symbols": ["release_lease", "guard_order"]})
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['name']\n"})
        matching = self.split(boundary={"paths": ["safety/x.py", "services/lease_release.py"],
                                        "symbols": ["guard_order", "release_lease"]})
        checks = self.check(self.evidence(head, declared_t="T1", split=matching))
        self.assert_case(checks, "split", "PASS", "SPLIT_PERIPHERAL_CLEAN")
        conflicting = self.split(boundary={"paths": ["other/"], "symbols": ["other_sym"]})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=conflicting)),
                         "split", "UNVERIFIED", "SPLIT_BOUNDARY_CONFLICT")

    def test_binary_and_unreadable_diff_is_needs_classification(self) -> None:
        self.release_core()
        head = self.commit({"ui/blob.bin": b"\x00\x01\x02\x03"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        self.assert_case(self.check(evidence), "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")
        evidence = self.evidence(head, declared_t="T1", split=self.split(), base="0" * 40)
        self.assert_case(self.check(evidence), "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")

    def test_behaviour_check_failed_or_malformed_is_unverified(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n"})
        declaration = self.split(behaviour_checks=[{"id": "golden", "result": "fail", "ref": "x"}])
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")
        declaration = self.split(behaviour_checks=[{"id": "golden"}])
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")
        declaration = self.split(behaviour_checks=[{"id": "golden", "result": "pass", "ref": "r"},
                                                   {"id": "io", "result": "pass"}])
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=declaration)),
                         "split", "PASS", "SPLIT_PERIPHERAL_CLEAN")

    def test_split_declaration_is_bound_to_previous_receipt(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n"})
        evidence = self.landed(self.evidence(head, declared_t="T1", split=self.split()))
        checks = self.check(evidence, "post-landing")
        self.assert_case(checks, "prior", "PASS", "PREVIOUS_RECEIPT_BOUND")
        evidence["split"]["contract_path"] = "splits/other.json"
        self.assert_case(self.check(evidence, "post-landing"), "prior",
                         "UNVERIFIED", "EVIDENCE_CHANGED")

    def test_split_mutants_are_assertion_red(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n",
                            "services/lease_release.py":
                            "def release_lease(order):\n    ledger.record(order)\n\n"
                            "def post_send_cleanup(order):\n    release_lease(order)\n    ledger.preserve(order)\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        with mock.patch.object(eligible, "_path_in_boundary", return_value=None):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(evidence), "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

        self.release_core()
        head = self.commit({"ui/dashboard.py":
                            "def render(row):\n    release_lease(row)\n    return str(row)\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        with mock.patch.object(eligible, "_leaf_hits", return_value=[]):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(evidence), "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

        self.seed({"services/order_flow.py":
                   "def settle(order):\n    return format_price(order['qty'])\n",
                   "ui/format.py": "def format_price(qty):\n    return f'{qty:.2f}'\n"})
        self.write_contract({"paths": ["services/"], "symbols": []})
        head = self.commit({"ui/format.py": "x = 1\n"})
        evidence = self.evidence(head, declared_t="T1", split=self.split())
        with mock.patch.object(eligible, "_referenced_from_boundary", return_value=[]):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(evidence), "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

        clean = self.evidence(self.commit({"ui/one.py": "print(1)\n"}), declared_t="T1",
                              split=self.split())
        with mock.patch.object(eligible, "_normalize_boundary", return_value=None):
            with self.assertRaises(AssertionError):
                self.assert_case(self.check(clean), "split", "PASS", "SPLIT_PERIPHERAL_CLEAN")

    def seed_pkg(self, consumer: str) -> None:
        """Package fixtures: boundary module under pkg/services, consumer in pkg/ui."""
        self.seed({"pkg/services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "pkg/ui/consumer.py": consumer,
                   self.CONTRACT: json.dumps({"boundary":
                                              {"paths": ["pkg/services/lease_release.py"],
                                               "symbols": ["release_lease"]}})})

    def test_relative_and_parenthesized_import_aliases_fail(self) -> None:
        base = ("from ..services.lease_release import release_lease as cleanup\n"
                "def render(row):\n    return str(row)\n")
        self.seed_pkg(base)
        head = self.commit({"pkg/ui/consumer.py":
                            "from ..services.lease_release import release_lease as cleanup\n"
                            "def render(row):\n    cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        base = ("from pkg.services.lease_release import (\n"
                "    release_lease as cleanup,\n)\n"
                "def render(row):\n    return str(row)\n")
        self.seed_pkg(base)
        head = self.commit({"pkg/ui/consumer.py": base.replace(
            "    return str(row)", "    cleanup(row)\n    return str(row)")})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_alias_chain_and_reexport_fail(self) -> None:
        base = ("from pkg.services.lease_release import release_lease as cleanup\n"
                "cleanup_alias = cleanup\n"
                "def render(row):\n    return str(row)\n")
        self.seed_pkg(base)
        head = self.commit({"pkg/ui/consumer.py": base.replace(
            "    return str(row)", "    cleanup_alias(row)\n    return str(row)")})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        # Re-export through a sibling module file.
        self.seed({"pkg/services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "pkg/ui/bridge.py":
                   "from pkg.services.lease_release import release_lease as cleanup\n",
                   "pkg/ui/consumer.py":
                   "from pkg.ui.bridge import cleanup as do_cleanup\n"
                   "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary":
                                              {"paths": ["pkg/services/lease_release.py"],
                                               "symbols": ["release_lease"]}})})
        head = self.commit({"pkg/ui/consumer.py":
                            "from pkg.ui.bridge import cleanup as do_cleanup\n"
                            "def render(row):\n    do_cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        # Star re-export inherits the bridge's bound names.
        self.commit({"pkg/ui/consumer.py":
                     "from pkg.ui.bridge import *\n"
                     "def render(row):\n    return str(row)\n"})
        self.base = git(self.repo, "rev-parse", "HEAD")
        head = self.commit({"pkg/ui/consumer.py":
                            "from pkg.ui.bridge import *\n"
                            "def render(row):\n    cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_unresolvable_star_import_is_needs_classification(self) -> None:
        self.seed_pkg("from totally_absent_pkg import *\n"
                      "def render(row):\n    return str(row)\n")
        head = self.commit({"pkg/ui/consumer.py":
                            "from totally_absent_pkg import *\n"
                            "def render(row):\n    anything(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")

    def test_dynamic_bound_name_activation_is_unverified(self) -> None:
        base = ("svc = object()\n"
                "fn = getattr(svc, 'relea' + 'se_lease')\n"
                "def render(row):\n    return str(row)\n")
        self.seed_pkg(base)
        head = self.commit({"pkg/ui/consumer.py": base.replace(
            "    return str(row)", "    fn(row)\n    return str(row)")})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")
        base = ("svc = object()\n"
                "fn = getattr(svc, 'release_lease')\n"
                "def render(row):\n    return str(row)\n")
        self.seed_pkg(base)
        head = self.commit({"pkg/ui/consumer.py": base.replace(
            "    return str(row)", "    fn(row)\n    return str(row)")})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def eval_bound(self, evidence: dict) -> tuple[dict, dict]:
        with mock.patch.object(eligible, "_read_pane", return_value=None):
            return eligible.evaluate(evidence, "pre-spawn", self.policy, self.policy_check)

    def test_submodule_import_and_module_alias_calls_fail(self) -> None:
        # `from pkg.ui import bridge` binds a module handle; bridge.cleanup is core.
        self.seed({"pkg/services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "pkg/ui/bridge.py":
                   "from pkg.services.lease_release import release_lease as cleanup\n",
                   "pkg/ui/consumer.py":
                   "from pkg.ui import bridge\n"
                   "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary":
                                              {"paths": ["pkg/services/lease_release.py"],
                                               "symbols": ["release_lease"]}})})
        head = self.commit({"pkg/ui/consumer.py":
                            "from pkg.ui import bridge\n"
                            "def render(row):\n    bridge.cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        # `import pkg.ui.bridge as b` binds the same handle under b.
        self.commit({"pkg/ui/consumer.py":
                     "import pkg.ui.bridge as b\n"
                     "def render(row):\n    return str(row)\n"})
        self.base = git(self.repo, "rev-parse", "HEAD")
        head = self.commit({"pkg/ui/consumer.py":
                            "import pkg.ui.bridge as b\n"
                            "def render(row):\n    b.cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_package_shadows_sibling_module_for_reexports(self) -> None:
        # Both bridge.py and bridge/__init__.py exist; Python prefers the package.
        self.seed({"pkg/services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "pkg/ui/bridge.py": "unrelated = 1\n",
                   "pkg/ui/bridge/__init__.py":
                   "from pkg.services.lease_release import release_lease as cleanup\n",
                   "pkg/ui/consumer.py":
                   "from pkg.ui.bridge import cleanup as do_cleanup\n"
                   "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary":
                                              {"paths": ["pkg/services/lease_release.py"],
                                               "symbols": ["release_lease"]}})})
        head = self.commit({"pkg/ui/consumer.py":
                            "from pkg.ui.bridge import cleanup as do_cleanup\n"
                            "def render(row):\n    do_cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_deep_reexport_past_depth_is_needs_classification(self) -> None:
        self.seed({"pkg/services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "pkg/ui/b1.py":
                   "from pkg.services.lease_release import release_lease as cleanup\n",
                   "pkg/ui/b2.py": "from pkg.ui.b1 import cleanup\n",
                   "pkg/ui/b3.py": "from pkg.ui.b2 import cleanup\n",
                   "pkg/ui/b4.py": "from pkg.ui.b3 import cleanup\n",
                   "pkg/ui/consumer.py":
                   "from pkg.ui.b4 import cleanup\n"
                   "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary":
                                              {"paths": ["pkg/services/lease_release.py"],
                                               "symbols": ["release_lease"]}})})
        head = self.commit({"pkg/ui/consumer.py":
                            "from pkg.ui.b4 import cleanup\n"
                            "def render(row):\n    cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")

    def test_backslash_continued_import_alias_fails(self) -> None:
        base = ("from pkg.services.lease_release import \\\n"
                "    release_lease as cleanup\n"
                "def render(row):\n    return str(row)\n")
        self.seed_pkg(base)
        head = self.commit({"pkg/ui/consumer.py": base.replace(
            "    return str(row)", "    cleanup(row)\n    return str(row)")})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_long_alias_chain_converges_or_is_unverified(self) -> None:
        base = "from pkg.services.lease_release import release_lease\n"
        base += "".join(f"x{index} = x{index + 1}\n" for index in range(7))
        base += "x7 = release_lease\ndef render(row):\n    return str(row)\n"
        self.seed_pkg(base)
        head = self.commit({"pkg/ui/consumer.py": base.replace(
            "    return str(row)", "    x0(row)\n    return str(row)")})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_dynamic_assignment_target_forms_are_unverified(self) -> None:
        for lhs in ("fn, unused = (getattr(svc, key), None)",
                    "fn: object = getattr(svc, key)",
                    "if True: fn = getattr(svc, key)"):
            with self.subTest(lhs=lhs):
                base = ("from pkg.services.lease_release import Service as svc\n"
                        "key = 'release_lease'\n" + lhs + "\n"
                        "def render(row):\n    return str(row)\n")
                self.seed_pkg(base)
                head = self.commit({"pkg/ui/consumer.py": base.replace(
                    "    return str(row)", "    fn(row)\n    return str(row)")})
                self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                          split=self.split())),
                                 "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")

    def test_module_reference_assignment_binds_handle(self) -> None:
        self.seed({"pkg/services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "pkg/ui/bridge.py":
                   "from pkg.services.lease_release import release_lease as cleanup\n",
                   "pkg/ui/consumer.py":
                   "import pkg.ui.bridge\nh = pkg.ui.bridge\n"
                   "def render(row):\n    return str(row)\n",
                   self.CONTRACT: json.dumps({"boundary":
                                              {"paths": ["pkg/services/lease_release.py"],
                                               "symbols": ["release_lease"]}})})
        head = self.commit({"pkg/ui/consumer.py":
                            "import pkg.ui.bridge\nh = pkg.ui.bridge\n"
                            "def render(row):\n    h.cleanup(row)\n    return str(row)\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def seed_handle_chain(self, sub_files: dict[str, str], consumer: str) -> None:
        """Boundary + pkg.ui.bridge + nested submodules + consumer."""
        files = {"pkg/services/lease_release.py":
                 "def release_lease(order):\n    ledger.record(order)\n",
                 "pkg/ui/bridge/__init__.py":
                 "from pkg.services.lease_release import release_lease as cleanup\n",
                 "pkg/ui/consumer.py": consumer,
                 self.CONTRACT: json.dumps({"boundary":
                                            {"paths": ["pkg/services/lease_release.py"],
                                             "symbols": ["release_lease"]}})}
        files.update(sub_files)
        self.seed(files)

    def test_handle_prefixed_dotted_module_assignment_fails(self) -> None:
        # r4 shape: `h = bridge.sub` / `h = bridge.sub.path` resolves through
        # the recorded handle's module, not a root-level path.
        for stmt in ("h = bridge.sub", "h = bridge.sub.path"):
            with self.subTest(stmt=stmt):
                sub = {"pkg/ui/bridge/sub/path.py":
                       "from pkg.services.lease_release import release_lease as cleanup\n"}
                if stmt == "h = bridge.sub":
                    sub["pkg/ui/bridge/sub/__init__.py"] = (
                        "from pkg.services.lease_release import release_lease as cleanup\n")
                base = ("import pkg.ui.bridge.sub.path\n"
                        "from pkg.ui import bridge\n" + stmt + "\n"
                        "def render(row):\n    return str(row)\n")
                self.seed_handle_chain(sub, base)
                head = self.commit({"pkg/ui/consumer.py": base.replace(
                    "    return str(row)", "    h.cleanup(row)\n    return str(row)")})
                self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                          split=self.split())),
                                 "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_same_class_dotted_variants_fail(self) -> None:
        # Variants of the handle/chain class: a handle-attr alias, a nested
        # chain call, and a plain-import dotted call all reach core.
        for head_body in (
                "x = bridge.cleanup\ndef render(row):\n    x(row)\n    return str(row)\n",
                "def render(row):\n    bridge.sub.cleanup(row)\n    return str(row)\n",
                "import pkg.ui.bridge.sub\ndef render(row):\n"
                "    pkg.ui.bridge.sub.cleanup(row)\n    return str(row)\n"):
            with self.subTest(head=head_body):
                base = ("import pkg.ui.bridge.sub\nfrom pkg.ui import bridge\n"
                        "def render(row):\n    return str(row)\n")
                self.seed_handle_chain({"pkg/ui/bridge/sub/__init__.py":
                                        "from pkg.services.lease_release import "
                                        "release_lease as cleanup\n"},
                                       base)
                head = self.commit({"pkg/ui/consumer.py":
                                    ("import pkg.ui.bridge.sub\n"
                                     "from pkg.ui import bridge\n" + head_body)})
                self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                          split=self.split())),
                                 "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")

    def test_unresolvable_binding_is_needs_classification(self) -> None:
        # A call through a name whose binding cannot be resolved or proven
        # non-core is UNVERIFIED, never a lower-T pass.
        for body in ("def render(row):\n    x = make_thing()\n    x(row)\n    return str(row)\n",
                     "y = helper\ndef render(row):\n    x = y\n    x(row)\n    return str(row)\n",
                     "def render(row):\n    x = row['fn']\n    x(row)\n    return str(row)\n",
                     "from totally_missing import run\n"
                     "def render(row):\n    run(row)\n    return str(row)\n"):
            with self.subTest(body=body.splitlines()[-2].strip()):
                self.seed_pkg("def render(row):\n    return str(row)\n")
                head = self.commit({"pkg/ui/consumer.py": body})
                self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                          split=self.split())),
                                 "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")

    def test_unproven_binding_without_call_stays_clean(self) -> None:
        # Unproven-value bindings only flag calls: data references stay clean.
        self.seed_pkg("def render(row):\n    return str(row)\n")
        head = self.commit({"pkg/ui/consumer.py":
                            "def render(row):\n    x = row['qty']\n    return x\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1",
                                                  split=self.split())),
                         "split", "PASS", "SPLIT_PERIPHERAL_CLEAN")

    def test_decode_error_keeps_touch_and_lists_unverifiable(self) -> None:
        self.release_core()
        head = self.commit({"a_touch.py": "release_lease(row)\n",
                            "z_bad.py": b"\xff = 2\n"})
        checks, bound = self.eval_bound(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        self.assertIn("a_touch.py", {item["path"] for item in checks["split"]["touches"]})
        self.assertEqual(bound["split_analysis"]["unverifiable"], ["z_bad.py"])

    def test_decode_error_alone_is_needs_classification(self) -> None:
        self.release_core()
        head = self.commit({"z_bad.py": b"\xff = 2\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "UNVERIFIED", "NEEDS_CLASSIFICATION")

    def test_symlink_contract_is_boundary_missing(self) -> None:
        self.seed({"pkg/services/lease_release.py":
                   "def release_lease(order):\n    ledger.record(order)\n",
                   "ui/dashboard.py": "def render(row):\n    return str(row)\n"})
        splits = self.repo / "splits"
        splits.mkdir(exist_ok=True)
        os.symlink('{"boundary": {"paths": ["pkg/services/lease_release.py"],'
                   ' "symbols": ["release_lease"]}}', splits / "733.json")
        git(self.repo, "add", "-A", ".")
        git(self.repo, "commit", "-qm", "contract")
        self.base = git(self.repo, "rev-parse", "HEAD")
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n"})
        self.assert_case(self.check(self.evidence(head, declared_t="T1", split=self.split())),
                         "split", "UNVERIFIED", "SPLIT_BOUNDARY_MISSING")

    def test_contract_tamper_receipt_keeps_contract_fields(self) -> None:
        self.release_core()
        head = self.commit({"ui/extra.py": "print('x')\n",
                            self.CONTRACT: json.dumps({"boundary": {"paths": [], "symbols": []}})})
        checks, bound = self.eval_bound(self.evidence(head, declared_t="T1", split=self.split()))
        self.assert_case(checks, "split", "FAIL", "PERIPHERAL_TOUCHES_CORE")
        analysis = bound["split_analysis"]
        self.assertEqual(analysis["contract_path"], self.CONTRACT)
        self.assertIsNotNone(analysis["contract_sha256"])
        self.assertEqual(analysis["core_touches"],
                         [{"path": self.CONTRACT, "kind": "contract"}])

    def test_malformed_split_keeps_analysis_stub(self) -> None:
        self.release_core()
        head = self.commit({"ui/dashboard.py": "def render(row):\n    return row['label']\n"})
        evidence = self.evidence(head, declared_t="T1", split=[])
        checks, bound = self.eval_bound(evidence)
        self.assert_case(checks, "split", "UNVERIFIED", "SPLIT_INVALID")
        analysis = bound["split_analysis"]
        self.assertIsNotNone(analysis)
        self.assertEqual(sorted(analysis), sorted(
            ["part", "parent_task", "paths_checked", "core_touches", "unverifiable",
             "boundary_sha256", "contract_path", "contract_sha256", "behaviour_checks"]))


if __name__ == "__main__":
    unittest.main()
