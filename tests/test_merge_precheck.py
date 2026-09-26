"""Contract fixtures and assertion-RED mutants for the shadow merge gate."""

from __future__ import annotations

import copy
import json
import re
import sys
import tempfile
import unittest
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "director"))

import merge_precheck as gate
import ci_canonical
from gate_common import load_policy, resolve_profile, write_receipt


H = "a" * 40
B = "b" * 40
M = "c" * 40
OTHER = "d" * 40


def policy() -> dict:
    loaded, check = load_policy(ROOT / "director/gate_policy.json", now=datetime(2026, 9, 26, tzinfo=timezone.utc), merge_required=True)
    if check["status"] != "PASS":
        raise AssertionError(check)
    return loaded


def snapshot() -> dict:
    repo = "mgh3326/agent-skills"
    pr = 999
    url = f"https://github.com/{repo}/pull/{pr}"
    job = "task727-builder"
    report_path = "/tmp/task727-builder-report.md"
    run = {"id": 10, "path": ".github/workflows/ci.yml", "head_sha": H, "event": "pull_request",
           "created_at": "2026-09-25T07:00:00Z", "run_started_at": "2026-09-25T07:00:00Z", "run_attempt": 1, "status": "completed", "conclusion": "success",
           "pull_requests": [{"base": {"sha": B}}]}
    jobs = [{"id": i, "name": name, "run_id": 10, "run_attempt": 1, "head_sha": H, "status": "completed",
             "conclusion": "success", "tested_base_sha": B, "tested_merge_sha": "e" * 40, "tested_merge_tree": M,
             "steps": [{"name": "Bash tests", "status": "completed", "conclusion": "success"}]}
            for i, name in enumerate(("ubuntu-latest", "macos-latest"), 1)]
    tester = {"ref": {"path": "/tmp/tester-report.md", "sha256": "e" * 64}, "verdict": "PASS", "H": H,
              "metadata": {"TASK": "727", "REPO": repo, "PR": str(pr), "TESTER_JOB": "task727-tester", "TESTER_SESSION": "tester-grok"}, "issues": [], "text": ""}
    builder = {"ref": {"path": report_path, "sha256": "f" * 64}, "verdict": "PASS", "H": H, "metadata": {}, "issues": [], "text": ""}
    return {"repo": repo, "PR": pr, "task": 727, "job": job, "issuer": "director-1", "time": "2026-09-25T08:00:00Z",
            "H": H, "B": B, "M": M, "expected_H": H, "head_ref_sha": H, "base_ref_sha": B,
            "head_to_base": {"ahead_by": 0}, "merge_parents": [B, H], "pr_url": url, "pr_body": "", "deploy_note": "",
            "tester_report": tester, "builder_report": builder, "eligibility_receipt": None,
            "tester_events": [{"job_id": "task727-tester", "kind": "job.spawned", "payload": {"label": "tester-grok", "pane_id": "synthetic-pane"}},
                              {"job_id": "task727-tester", "kind": "job.completed", "payload": {"report_path": "/tmp/tester-report.md", "report_sha256": "e" * 64}}],
            "runtime_receipt": None, "hash_receipt": None, "ci_runs": [run], "ci_jobs": {10: jobs},
            "protection_contexts": None, "files": [{"filename": "README.md", "status": "modified", "patch": "@@ -1 +1 @@\n+hello"}],
            "scan": {"complete": True, "B": B, "H": H, "scanner": "gitleaks+patterns", "version": "8.30.1", "exit_code": 0, "hits": []},
            "surface_class": "code_or_docs", "task_record": {"id": 727, "state": "in_progress", "lane": "director-1", "refs": {"job_id": job}},
            "job_events": [{"kind": "job.claim", "payload": {"parent_lane": "director-1", "owner_lane": "b727", "role": "builder"}},
                           {"kind": "job.joined", "payload": {"pr": url, "head": H, "report_path": report_path}}]}


def assert_check(test: unittest.TestCase, s: dict, key: str, status: str, code: str) -> None:
    actual = gate.evaluate(s, policy())[key]
    test.assertEqual((status, code), (actual["status"], actual["reason_code"]))


def canonical_run(
    run_id: int, attempt: int, *, conclusion: str | None = "success",
    started_at: str | None = "2026-09-25T07:00:00Z",
    created_at: str = "2026-09-25T07:00:00Z",
    path: str = ".github/workflows/ci.yml",
) -> dict:
    return {"id": run_id, "path": path, "head_sha": H, "event": "pull_request",
            "created_at": created_at, "run_started_at": started_at, "run_attempt": attempt,
            "status": "completed", "conclusion": conclusion}


def canonical_jobs(repo: str, run: dict, conclusion: str = "success") -> list[dict]:
    loaded = policy()
    workflows = loaded["ci"][repo]
    execution = loaded["ci_execution_steps"][repo]
    names = [name for workflow_names in workflows.values() for name in workflow_names]
    return [{"id": run["id"] * 100 + run["run_attempt"] * 10 + index, "name": name,
             "run_id": run["id"], "run_attempt": run["run_attempt"], "head_sha": H,
             "status": "completed", "conclusion": conclusion, "tested_base_sha": B,
             "tested_merge_sha": M, "tested_merge_tree": "e" * 40,
             "steps": [{"name": marker, "status": "completed", "conclusion": "success"}
                       for marker in execution[name]]}
            for index, name in enumerate(names, 1)]


def canonical_jobs_by_run(repo: str, runs: list[dict]) -> dict[int, list[dict]]:
    jobs: dict[int, list[dict]] = {}
    seen_attempts: set[tuple[int, int]] = set()
    for run in runs:
        identity = (run["id"], run["run_attempt"])
        if identity in seen_attempts:
            continue
        seen_attempts.add(identity)
        jobs.setdefault(run["id"], []).extend(canonical_jobs(repo, run))
    return jobs


def evaluate_canonical_ci(repo: str, runs: list[dict], evaluator=None) -> dict:
    loaded = policy()
    protection = loaded["ci"][repo].get("branch_protection")
    return (evaluator or ci_canonical.evaluate_required_ci)(
        loaded, repo, H, B, runs, canonical_jobs_by_run(repo, runs), protection)


def canonical_ci_mutant(replacements: list[tuple[str, str]]):
    source = (ROOT / "director/ci_canonical.py").read_text()
    for old, new in replacements:
        if source.count(old) != 1:
            raise AssertionError(f"expected one mutation target: {old!r}")
        source = source.replace(old, new)
    namespace: dict = {"__name__": "ci_canonical_assertion_red_mutant"}
    exec(compile(source, "director/ci_canonical.py", "exec"), namespace)
    return namespace["evaluate_required_ci"]


def merge_precheck_mutant(replacements: list[tuple[str, str]]):
    source = (ROOT / "director/merge_precheck.py").read_text()
    for old, new in replacements:
        if source.count(old) != 1:
            raise AssertionError(f"expected one mutation target: {old!r}")
        source = source.replace(old, new)
    namespace: dict = {"__name__": "merge_precheck_assertion_red_mutant"}
    exec(compile(source, "director/merge_precheck.py", "exec"), namespace)
    return namespace["checkout_merge_sha"]


CHECKOUT_STAMP = "ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:00Z "


def checkout_log(abbrev: str | None, checkout_sha: str, extra_announces: list[str] | None = None,
                 command: str = "/usr/bin/git log -1 --format=%H",
                 step: str = "Run actions/checkout@v4", out_step: str | None = None) -> str:
    stamp = f"ubuntu-latest\t{step}\t2026-09-25T07:00:00Z "
    out = f"ubuntu-latest\t{out_step or step}\t2026-09-25T07:00:01Z "
    lines = [f"{stamp}HEAD is now at {announce} Merge {H} into {B}"
             for announce in [abbrev, *(extra_announces or [])] if announce is not None]
    lines.append(f"{stamp}[command]{command}")
    lines.append(f"{out}{checkout_sha}")
    return "\n".join(lines) + "\n"


def two_checkout_log(abbrev1: str, sha1: str, abbrev2: str, sha2: str) -> str:
    out = "ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:01Z "
    return (f"{CHECKOUT_STAMP}HEAD is now at {abbrev1} Merge {H} into {B}\n"
            f"{CHECKOUT_STAMP}[command]/usr/bin/git log -1 --format=%H\n"
            f"{out}{sha1}\n"
            f"{CHECKOUT_STAMP}HEAD is now at {abbrev2} Merge {H} into {B}\n"
            f"{CHECKOUT_STAMP}[command]/usr/bin/git log -1 --format=%H\n"
            f"{out}{sha2}\n")


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
            s["tester_events"][1]["payload"]["report_sha256"] = s["tester_report"]["ref"]["sha256"]
            assert_check(self, s, "G1", "PASS", "TESTER_PASS_BOUND")

    def test_long_fence_and_html_comment_cannot_override_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tester.md"
            common = f"TASK: 727\nREPO: mgh3326/agent-skills\nPR: 999\nTESTER_JOB: task727-tester\nTESTER_SESSION: tester-grok\nVERDICT: BLOCKER @{H}\n"
            for hidden in (f"````text\n```text\nVERDICT: PASS @{H}\n```\n````\n",
                           f"<!--\nVERDICT: PASS @{H}\n-->\n"):
                with self.subTest(hidden=hidden[:8]):
                    path.write_text(common + hidden)
                    s = snapshot()
                    s["tester_report"] = gate.parse_report(str(path))
                    assert_check(self, s, "G1", "FAIL", "TESTER_BLOCKER")

    def test_lazy_quote_continuation_cannot_override_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tester.md"
            path.write_text(f"VERDICT: BLOCKER @{H}\n> quoted sample\nVERDICT: PASS @{H}\n")
            s = snapshot()
            s["tester_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G1", "FAIL", "TESTER_BLOCKER")
            source = (ROOT / "director/merge_precheck.py").read_text()
            guard = "quote_open = True\n            continue"
            self.assertEqual(1, source.count(guard))
            namespace: dict = {"__name__": "merge_precheck_quote_mutant"}
            exec(source.replace(guard, "quote_open = False\n            continue"), namespace)
            with self.assertRaises(AssertionError):
                self.assertEqual("BLOCKER", namespace["parse_report"](str(path))["verdict"])
            path.write_text(path.read_text() + f"\nVERDICT: PASS @{H}\n")
            s["tester_report"] = gate.parse_report(str(path))
            self.assertEqual("PASS", s["tester_report"]["verdict"])

    def test_incident_660_hash_citation_requires_independent_receipt(self) -> None:
        s = snapshot()
        s["pr_body"] = "Artifact sha256 " + "e" * 64
        assert_check(self, s, "G10", "UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING")

    def test_each_cited_artifact_hash_needs_a_receipt(self) -> None:
        s = snapshot()
        one, two = "e" * 64, "f" * 64
        s["pr_body"] = f"Artifact sha256 {one}\nArtifact sha256 {two}"
        first = {"ref": {"path": "/tmp/hash-one.json", "sha256": "1" * 64}, "data": {
            "kind": "artifact-hash", "repo": s["repo"], "PR": 999, "H": H, "issuer": "independent-builder",
            "sha256": one, "artifact_ref": "artifact/one"}}
        s["hash_receipts"] = [first]
        assert_check(self, s, "G10", "UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING")
        second = copy.deepcopy(first)
        second["ref"]["path"] = "/tmp/hash-two.json"
        second["data"]["sha256"] = two
        second["data"]["artifact_ref"] = "artifact/two"
        s["hash_receipts"].append(second)
        assert_check(self, s, "G10", "PASS", "ARTIFACT_HASH_INDEPENDENT")

    def test_malformed_nested_receipts_are_unverified(self) -> None:
        s = snapshot()
        s["eligibility_receipt"] = {"ref": {"path": "/tmp/eligible.json", "sha256": "1" * 64}, "data": {
            "kind": "spawn", "task": 727, "repo": s["repo"], "PR": s["PR"], "H": H,
            "tester_job": "task727-tester", "checks": ["PASS"]}}
        assert_check(self, s, "G1", "UNVERIFIED", "ELIGIBILITY_NOT_PASS")
        s = snapshot()
        s["pr_body"] = "Artifact sha256 " + "e" * 64
        s["hash_receipts"] = [{"ref": {"path": "/tmp/hash.json", "sha256": "1" * 64}, "data": {
            "kind": "artifact-hash", "repo": s["repo"], "PR": s["PR"], "H": H,
            "issuer": "independent-builder", "sha256": None, "artifact_ref": "artifact/one"}}]
        assert_check(self, s, "G10", "UNVERIFIED", "ARTIFACT_HASH_UNBOUND")
        s["hash_receipts"][0]["data"].update(sha256="e" * 64, artifact_ref=["artifact/one"])
        assert_check(self, s, "G10", "UNVERIFIED", "ARTIFACT_HASH_UNBOUND")
        s = snapshot()
        s["task_record"]["refs"] = None
        assert_check(self, s, "G8", "UNVERIFIED", "QUEUE_LOOKUP_FAILED")
        s["files"] = [None]
        assert_check(self, s, "G5", "UNVERIFIED", "DIFF_LOOKUP_FAILED")
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_DIFF_UNKNOWN")

    def test_incident_t3_misassignment_and_same_family_t3(self) -> None:
        s = snapshot()
        s["eligibility_receipt"] = {"ref": {"path": "/tmp/eligible.json", "sha256": "0" * 64},
                                    "data": {"kind": "spawn", "task": 727, "repo": s["repo"], "PR": 999, "H": H,
                                             "tester_job": "task727-tester", "checks": {"grade": {"status": "FAIL", "reason_code": "T3_DS41_NOT_ALLOWED"}}}}
        assert_check(self, s, "G1", "FAIL", "ELIGIBILITY_NOT_PASS")
        s["eligibility_receipt"]["data"]["checks"] = {"family": {"status": "FAIL", "reason_code": "T3_SAME_FAMILY"}}
        assert_check(self, s, "G1", "FAIL", "ELIGIBILITY_NOT_PASS")
        self.assertIn("A+ reversible T1/T2", policy()["sources"]["decision/2026-09-20/provider-family-and-ds41-grade"]["scope"])

    def test_policy_unknown_stale_conflict(self) -> None:
        path = ROOT / "director/gate_policy.json"
        self.assertEqual("POLICY_STALE", load_policy(path, now=datetime(2026, 10, 3, tzinfo=timezone.utc), merge_required=True)[1]["reason_code"])
        with tempfile.TemporaryDirectory() as directory:
            p = json.loads(path.read_text())
            p["conflicts"] = ["test conflict"]
            target = Path(directory) / "policy.json"
            target.write_text(json.dumps(p))
            self.assertEqual("POLICY_CONFLICT", load_policy(target, now=datetime(2026, 9, 26, tzinfo=timezone.utc), merge_required=True)[1]["reason_code"])
            p["conflicts"] = []
            del p["ci"]["mgh3326/agent-skills"]
            target.write_text(json.dumps(p))
            self.assertEqual("POLICY_CI_EXECUTION_UNKNOWN", load_policy(target, now=datetime(2026, 9, 26, tzinfo=timezone.utc), merge_required=True)[1]["reason_code"])
            self.assertEqual("CI_POLICY_UNKNOWN", gate.evaluate(snapshot(), p)["G3"]["reason_code"])
            for field, value, reason in (("runtime", [], "POLICY_RUNTIME_UNKNOWN"),
                                         ("artifact_paths", [], "POLICY_ARTIFACT_PATHS_UNKNOWN"),
                                         ("ci_execution_steps", {}, "POLICY_CI_EXECUTION_UNKNOWN"),
                                         ("effective_at", {}, "POLICY_CONFLICT")):
                invalid = json.loads(path.read_text())
                invalid[field] = value
                target.write_text(json.dumps(invalid))
                self.assertEqual(reason, load_policy(target, now=datetime(2026, 9, 26, tzinfo=timezone.utc), merge_required=True)[1]["reason_code"])

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
        late["run_started_at"] = "2026-09-25T07:05:00Z"
        late["conclusion"] = "failure"
        s["ci_runs"].append(late)
        s["ci_jobs"][11] = copy.deepcopy(s["ci_jobs"][10])
        for job in s["ci_jobs"][11]:
            job["run_id"] = 11
        s["ci_jobs"][11][0]["conclusion"] = "failure"
        assert_check(self, s, "G3", "FAIL", "CI_FAILED")
        s = snapshot()
        s["ci_jobs"][10] = s["ci_jobs"][10][:1]
        s["ci_jobs"][10][0]["conclusion"] = "failure"
        assert_check(self, s, "G3", "FAIL", "CI_FAILED")

    def test_ci_red_rerun_is_not_met_with_assertion_red_mutant(self) -> None:
        s = snapshot()
        s["ci_runs"][0].update({"run_attempt": 2, "conclusion": "failure"})
        for job in s["ci_jobs"][10]:
            job["run_attempt"] = 2
            job["conclusion"] = "failure"
        newer_green = copy.deepcopy(snapshot()["ci_runs"][0])
        newer_green.update({"id": 11, "created_at": "2026-09-25T07:05:00Z", "run_started_at": "2026-09-25T07:05:00Z"})
        s["ci_runs"].append(newer_green)
        s["ci_jobs"][11] = copy.deepcopy(snapshot()["ci_jobs"][10])
        for job in s["ci_jobs"][11]:
            job["run_id"] = 11
            job["id"] += 100
        assert_check(self, s, "G3", "FAIL", "CI_FAILED")
        source = (ROOT / "director/ci_canonical.py").read_text()
        guard = "run_problem = _run_attempt_problem(run)"
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "ci_rerun_red_mutant"}
        exec(source.replace(guard, "run_problem = None"), namespace)
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_FAILED", mutant["reason_code"])

    def test_ci_retry_without_a_start_time_fails_closed_after_identity_validation(self) -> None:
        def retry_without_start(attempt: object) -> dict:
            s = snapshot()
            red = copy.deepcopy(s["ci_runs"][0])
            red.update({"run_attempt": attempt, "conclusion": "failure"})
            red.pop("run_started_at")
            green = copy.deepcopy(s["ci_runs"][0])
            green.update({"id": 11, "created_at": "2026-09-25T07:05:00Z", "run_started_at": "2026-09-25T07:05:00Z"})
            s["ci_runs"] = [red, green]
            s["ci_jobs"][11] = copy.deepcopy(s["ci_jobs"][10])
            for job in s["ci_jobs"][11]:
                job["id"] += 100
                job["run_id"] = 11
            return s

        # #732 rejects malformed attempt identities before timestamp selection.
        # The valid retry below still proves that a missing start time fails closed.
        for attempt, expected_code in (
            (2, "CI_RUN_TIME_INVALID"),
            ("2", "CI_RUN_IDENTITY_INVALID"),
            (None, "CI_RUN_IDENTITY_INVALID"),
            (True, "CI_RUN_IDENTITY_INVALID"),
            (2.0, "CI_RUN_IDENTITY_INVALID"),
            (0, "CI_RUN_IDENTITY_INVALID"),
            (-1, "CI_RUN_IDENTITY_INVALID"),
        ):
            with self.subTest(attempt=attempt):
                s = retry_without_start(attempt)
                assert_check(self, s, "G3", "UNVERIFIED", expected_code)
        source = (ROOT / "director/ci_canonical.py").read_text()
        fallback = "if raw is None and type(attempt) is int and attempt == 1:"
        self.assertEqual(1, source.count(fallback))
        s = retry_without_start(2)
        namespace: dict = {"__name__": "ci_retry_time_mutant"}
        exec(source.replace(fallback, "if raw is None:"), namespace)
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_RUN_TIME_INVALID", mutant["reason_code"])

    def test_ci_collector_race_with_newer_job_attempt_is_not_met(self) -> None:
        for status, conclusion in (("completed", "failure"), ("in_progress", None)):
            with self.subTest(status=status):
                s = snapshot()
                s["ci_jobs"][10] += [
                    {**copy.deepcopy(job), "id": job["id"] + 100, "run_attempt": 2,
                     "status": status, "conclusion": conclusion}
                    for job in s["ci_jobs"][10]
                ]
                assert_check(self, s, "G3", "UNVERIFIED", "CI_EVIDENCE_BINDING_INVALID")
        source = (ROOT / "director/ci_canonical.py").read_text()
        guard = "if _job_attempt_is_invalid_for_selected_run(run, job):"
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "ci_collector_race_mutant"}
        exec(source.replace(guard, "if False:"), namespace)
        s = snapshot()
        s["ci_jobs"][10] += [
            {**copy.deepcopy(job), "id": job["id"] + 100, "run_attempt": 2, "conclusion": "failure"}
            for job in s["ci_jobs"][10]
        ]
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_EVIDENCE_BINDING_INVALID", mutant["reason_code"])
        source_guard = "if type(run_id) is not int or type(job.get(\"run_id\")) is not int or job.get(\"run_id\") != run_id:"
        self.assertEqual(1, source.count(source_guard))
        s = snapshot()
        s["ci_jobs"][10] += [
            {**copy.deepcopy(job), "id": job["id"] + 200, "run_id": 9, "run_attempt": 0}
            for job in s["ci_jobs"][10]
        ]
        assert_check(self, s, "G3", "UNVERIFIED", "CI_EVIDENCE_BINDING_INVALID")
        namespace = {"__name__": "ci_foreign_job_mutant"}
        exec(source.replace(source_guard, "if False:"), namespace)
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_EVIDENCE_BINDING_INVALID", mutant["reason_code"])

    def test_selected_non_success_workflow_cannot_count_as_green_ci(self) -> None:
        for conclusion in ("failure", "cancelled", "timed_out", "startup_failure"):
            with self.subTest(conclusion=conclusion):
                s = snapshot()
                s["ci_runs"][0]["conclusion"] = conclusion
                assert_check(self, s, "G3", "FAIL", "CI_FAILED")
        source = (ROOT / "director/ci_canonical.py").read_text()
        guard = "run_problem = _run_attempt_problem(run)"
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "ci_red_run_mutant"}
        exec(source.replace(guard, "run_problem = None"), namespace)
        s = snapshot()
        s["ci_runs"][0]["conclusion"] = "cancelled"
        green = copy.deepcopy(snapshot()["ci_runs"][0])
        green.update({"id": 11, "created_at": "2026-09-25T07:05:00Z", "run_started_at": "2026-09-25T07:05:00Z"})
        s["ci_runs"].append(green)
        s["ci_jobs"][11] = copy.deepcopy(s["ci_jobs"][10])
        for job in s["ci_jobs"][11]:
            job.update({"id": job["id"] + 100, "run_id": 11})
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_FAILED", mutant["reason_code"])

    def test_ci_per_check_identity_binding_has_assertion_red_mutant(self) -> None:
        s = snapshot()
        s["ci_jobs"][10][0]["id"] = "not-an-action-job-id"
        assert_check(self, s, "G3", "UNVERIFIED", "CI_EVIDENCE_BINDING_INVALID")
        source = (ROOT / "director/ci_canonical.py").read_text()
        guard = "if not _has_bound_identity(run, job, H):"
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "ci_identity_binding_mutant"}
        exec(source.replace(guard, "if False:"), namespace)
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_EVIDENCE_BINDING_INVALID", mutant["reason_code"])
    def test_ci_equal_start_times_from_different_runs_are_ambiguous(self) -> None:
        s = snapshot()
        s["ci_runs"][0].update({"run_attempt": 2, "conclusion": "failure"})
        for job in s["ci_jobs"][10]:
            job.update({"run_attempt": 2, "conclusion": "failure"})
        green = copy.deepcopy(snapshot()["ci_runs"][0])
        green["id"] = 11
        s["ci_runs"].append(green)
        s["ci_jobs"][11] = copy.deepcopy(snapshot()["ci_jobs"][10])
        for job in s["ci_jobs"][11]:
            job.update({"id": job["id"] + 100, "run_id": 11})
        assert_check(self, s, "G3", "UNVERIFIED", "CI_RUN_AMBIGUOUS")
        source = (ROOT / "director/ci_canonical.py").read_text()
        guard = "if _has_cross_run_tie(latest_attempts, order):"
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "ci_equal_time_mutant"}
        exec(source.replace(guard, "if False:"), namespace)
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_RUN_AMBIGUOUS", mutant["reason_code"])

    def test_required_test_step_must_execute(self) -> None:
        s = snapshot()
        s["ci_jobs"][10][0]["steps"] = [
            {"name": "Run actions/checkout@v4", "status": "completed", "conclusion": "success"},
            {"name": "Bash tests", "status": "completed", "conclusion": "skipped"}]
        assert_check(self, s, "G3", "FAIL", "CI_SKIPPED")
        s["ci_jobs"][10][0]["steps"].pop()
        assert_check(self, s, "G3", "UNVERIFIED", "CI_REQUIRED_STEP_MISSING")
        source = (ROOT / "director/ci_canonical.py").read_text()
        guard = 'for marker in execution[name]:'
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "ci_step_mutant"}
        exec(source.replace(guard, 'for marker in []:'), namespace)
        mutant = namespace["evaluate_required_ci"](policy(), s["repo"], H, B, s["ci_runs"], s["ci_jobs"])
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_REQUIRED_STEP_MISSING", mutant["reason_code"])

    def test_setup_step_cannot_stand_in_for_tests_and_run_time_is_chronological(self) -> None:
        self.assertTrue(ci_canonical._step_matches("go test", "Run go test ./..."))
        self.assertFalse(ci_canonical._step_matches("go test", "Setup go test ./..."))
        self.assertFalse(ci_canonical._step_matches("Bash tests", "Bash tests extra"))
        s = snapshot()
        s["ci_jobs"][10][0]["steps"] = [{"name": "Setup Bash tests", "status": "completed", "conclusion": "success"}]
        assert_check(self, s, "G3", "UNVERIFIED", "CI_REQUIRED_STEP_MISSING")
        with patch.object(ci_canonical, "_step_matches", side_effect=lambda marker, name: marker.casefold() in name.casefold()):
            with self.assertRaises(AssertionError):
                assert_check(self, s, "G3", "UNVERIFIED", "CI_REQUIRED_STEP_MISSING")
        s["ci_jobs"][10][0]["steps"][0]["name"] = "Bash tests extra"
        assert_check(self, s, "G3", "UNVERIFIED", "CI_REQUIRED_STEP_MISSING")
        s = snapshot()
        later = copy.deepcopy(s["ci_runs"][0])
        later["id"] = 11
        later["created_at"] = "2026-09-25T07:00:00.100Z"
        later["run_started_at"] = "2026-09-25T07:00:00.100Z"
        later["conclusion"] = "failure"
        s["ci_runs"].append(later)
        s["ci_jobs"][11] = copy.deepcopy(s["ci_jobs"][10])
        for job in s["ci_jobs"][11]:
            job["run_id"] = 11
            job["conclusion"] = "failure"
        assert_check(self, s, "G3", "FAIL", "CI_FAILED")
        s["ci_runs"][1]["run_started_at"] = "unknown"
        assert_check(self, s, "G3", "UNVERIFIED", "CI_RUN_TIME_INVALID")
        s["ci_runs"][1]["run_started_at"] = s["ci_runs"][0]["run_started_at"]
        assert_check(self, s, "G3", "UNVERIFIED", "CI_RUN_AMBIGUOUS")

    def test_branch_protection_same_second_runs_with_different_attempts_are_ambiguous(self) -> None:
        repo = "mgh3326/auto_trader"
        green = canonical_run(10, 2)
        red = canonical_run(11, 1, conclusion="failure")
        runs = [green, red]
        expected = ("UNVERIFIED", "CI_RUN_AMBIGUOUS")
        actual = evaluate_canonical_ci(repo, runs)
        self.assertEqual(expected, (actual["status"], actual["reason_code"]))

        green_tie = canonical_run(12, 2)
        red_tie = canonical_run(13, 1)
        tied = evaluate_canonical_ci(repo, [green_tie, red_tie])
        self.assertEqual(expected, (tied["status"], tied["reason_code"]))
        tie_evaluator = canonical_ci_mutant([
            ("if _has_cross_run_tie(latest_attempts, order):",
             "if False and _has_cross_run_tie(latest_attempts, order):")])
        with self.assertRaises(AssertionError):
            tied = evaluate_canonical_ci(repo, [green_tie, red_tie], tie_evaluator)
            self.assertEqual(expected, (tied["status"], tied["reason_code"]))

    def test_attempts_are_compared_within_the_same_run_id(self) -> None:
        repo = "mgh3326/auto_trader"
        failed_attempt = canonical_run(14, 1, conclusion="failure")
        successful_retry = canonical_run(14, 2, started_at="2026-09-25T07:01:00Z",
                                         created_at="2026-09-25T07:00:00Z")
        expected = ("PASS", "CI_ALL_REQUIRED_SUCCEEDED")
        actual = evaluate_canonical_ci(repo, [failed_attempt, successful_retry])
        self.assertEqual(expected, (actual["status"], actual["reason_code"]))
        reverse = evaluate_canonical_ci(repo, [successful_retry, failed_attempt])
        self.assertEqual(expected, (reverse["status"], reverse["reason_code"]))

        retry_evaluator = canonical_ci_mutant([
            ("if previous is None or attempt > previous[\"run_attempt\"]:",
             "if previous is None:")])
        with self.assertRaises(AssertionError):
            regressed = evaluate_canonical_ci(repo, [failed_attempt, successful_retry], retry_evaluator)
            self.assertEqual(expected, (regressed["status"], regressed["reason_code"]))

    def test_duplicate_run_attempt_listings_are_ambiguous(self) -> None:
        repo = "mgh3326/agent-skills"
        green_listing = canonical_run(20, 1, created_at="2026-09-25T07:01:00Z")
        red_listing = canonical_run(20, 1, conclusion="failure", created_at="2026-09-25T07:00:00Z")
        runs = [green_listing, red_listing]
        expected = ("UNVERIFIED", "CI_RUN_AMBIGUOUS")
        actual = evaluate_canonical_ci(repo, runs)
        self.assertEqual(expected, (actual["status"], actual["reason_code"]))

        duplicate_evaluator = canonical_ci_mutant([
            ("listing_problem = _candidate_listing_problem(runs, candidates)",
             "listing_problem = None")])
        with self.assertRaises(AssertionError):
            duplicate = evaluate_canonical_ci(repo, runs, duplicate_evaluator)
            self.assertEqual(expected, (duplicate["status"], duplicate["reason_code"]))

        reverse = evaluate_canonical_ci(repo, list(reversed(runs)))
        self.assertEqual(expected, (reverse["status"], reverse["reason_code"]))

    def test_same_run_id_with_conflicting_immutable_fields_is_unverified(self) -> None:
        repo = "mgh3326/agent-skills"
        green = canonical_run(21, 1)
        conflicting_rows = []
        for field, value in (("head_sha", OTHER), ("event", "push"),
                             ("path", ".github/workflows/other.yml")):
            conflict = copy.deepcopy(green)
            conflict["conclusion"] = "failure"
            conflict[field] = value
            conflicting_rows.append((field, [green, conflict]))
        other_path_retry = canonical_run(21, 2, conclusion="failure",
                                         started_at="2026-09-25T07:01:00Z",
                                         created_at="2026-09-25T07:00:00Z",
                                         path=".github/workflows/other.yml")
        conflicting_rows.append(("retry_path", [green, other_path_retry]))

        expected = ("UNVERIFIED", "CI_RUN_IDENTITY_INVALID")
        for name, runs in conflicting_rows:
            with self.subTest(conflict=name):
                actual = evaluate_canonical_ci(repo, runs)
                self.assertEqual(expected, (actual["status"], actual["reason_code"]))

        conflict = copy.deepcopy(green)
        conflict["head_sha"] = OTHER
        conflicting_evaluator = canonical_ci_mutant([
            ("listing_problem = _candidate_listing_problem(runs, candidates)",
             "listing_problem = None")])
        with self.assertRaises(AssertionError):
            hidden = evaluate_canonical_ci(repo, [green, conflict], conflicting_evaluator)
            self.assertEqual(expected, (hidden["status"], hidden["reason_code"]))

    def test_empty_run_started_at_does_not_fall_back_to_created_at(self) -> None:
        repo = "mgh3326/agent-skills"
        run = canonical_run(30, 1, started_at="", created_at="2026-09-25T07:00:00Z")
        expected = ("UNVERIFIED", "CI_RUN_TIME_INVALID")
        actual = evaluate_canonical_ci(repo, [run])
        self.assertEqual(expected, (actual["status"], actual["reason_code"]))

        timestamp_evaluator = canonical_ci_mutant([
            ("if raw is None and type(attempt) is int and attempt == 1:",
             "if (raw is None or raw == \"\") and type(attempt) is int and attempt == 1:")])
        with self.assertRaises(AssertionError):
            fallback = evaluate_canonical_ci(repo, [run], timestamp_evaluator)
            self.assertEqual(expected, (fallback["status"], fallback["reason_code"]))

        missing_retry_time = canonical_run(31, 2, started_at=None, created_at="2026-09-25T07:00:00Z")
        missing = evaluate_canonical_ci(repo, [missing_retry_time])
        self.assertEqual(expected, (missing["status"], missing["reason_code"]))

    def test_non_success_candidate_runs_never_hide_behind_a_newer_green_run(self) -> None:
        repo = "mgh3326/auto_trader"
        for conclusion in ("failure", "cancelled", "timed_out", "startup_failure"):
            with self.subTest(conclusion=conclusion):
                red = canonical_run(40, 1, conclusion=conclusion)
                green = canonical_run(41, 1, started_at="2026-09-25T07:01:00Z",
                                      created_at="2026-09-25T07:01:00Z")
                actual = evaluate_canonical_ci(repo, [red, green])
                self.assertEqual(("FAIL", "CI_FAILED"), (actual["status"], actual["reason_code"]))

        red = canonical_run(42, 1, conclusion="failure")
        green = canonical_run(43, 1, started_at="2026-09-25T07:01:00Z",
                              created_at="2026-09-25T07:01:00Z")
        failure_evaluator = canonical_ci_mutant([
            ("run_problem = _run_attempt_problem(run)", "run_problem = None")])
        with self.assertRaises(AssertionError):
            hidden = evaluate_canonical_ci(repo, [red, green], failure_evaluator)
            self.assertEqual(("FAIL", "CI_FAILED"), (hidden["status"], hidden["reason_code"]))

    def test_receipt_writer_rejects_reuse_of_action_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            receipt = {"action_id": "fixed-id", "kind": "merge", "checks": {}}
            path = write_receipt(receipt, Path(directory))
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                write_receipt({**receipt, "checks": {"G1": {"status": "PASS"}}}, Path(directory))
            self.assertEqual(original, path.read_bytes())

    def test_ci_checkout_provenance_ignores_mutable_pr_base(self) -> None:
        s = snapshot()
        s["ci_runs"][0]["pull_requests"][0]["base"]["sha"] = OTHER
        assert_check(self, s, "G3", "PASS", "CI_ALL_REQUIRED_SUCCEEDED")
        s["ci_jobs"][10][0]["tested_base_sha"] = OTHER
        assert_check(self, s, "G3", "UNVERIFIED", "CI_BASE_MOVED")
        s = snapshot()
        duplicate = copy.deepcopy(s["ci_jobs"][10][0])
        duplicate["id"] = 99
        duplicate["conclusion"] = "failure"
        s["ci_jobs"][10].append(duplicate)
        assert_check(self, s, "G3", "FAIL", "CI_FAILED")
        duplicate["conclusion"] = "success"
        assert_check(self, s, "G3", "UNVERIFIED", "CI_JOB_AMBIGUOUS")
        duplicate["conclusion"] = "skipped"
        assert_check(self, s, "G3", "FAIL", "CI_SKIPPED")

    def test_checkout_job_log_binds_trial_merge_parents(self) -> None:
        checkout_sha = "e" * 40
        log = (f"ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:00Z HEAD is now at {checkout_sha[:7]} Merge H into B\n"
               "ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:00Z "
               "[command]/usr/bin/git log -1 --format=%H\n"
               f"ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:01Z {checkout_sha}\n")
        with patch.object(gate, "run_text", return_value=log), patch.object(gate, "gh_api", return_value={
            "parents": [{"sha": B}, {"sha": H}], "tree": {"sha": M}}):
            self.assertEqual({"tested_base_sha": B, "tested_merge_sha": checkout_sha, "tested_merge_tree": M},
                             gate.checkout_provenance("mgh3326/agent-skills", 10, 1, H))
        self.assertIsNone(gate.checkout_merge_sha(log.replace(checkout_sha, "short-sha")))

    def test_checkout_merge_sha_accepts_7_to_40_char_abbreviations(self) -> None:
        checkout_sha = "e" * 40
        for length in (7, 9, 12, 40):
            with self.subTest(abbreviation_length=length):
                self.assertEqual(checkout_sha, gate.checkout_merge_sha(checkout_log(checkout_sha[:length], checkout_sha)))
        # The #711r incident shape: Actions printed 9 chars and G3 fell to CI_BASE_UNBOUND.
        with patch.object(gate, "run_text", return_value=checkout_log(checkout_sha[:9], checkout_sha)), patch.object(gate, "gh_api", return_value={
            "parents": [{"sha": B}, {"sha": H}], "tree": {"sha": M}}):
            self.assertEqual({"tested_base_sha": B, "tested_merge_sha": checkout_sha, "tested_merge_tree": M},
                             gate.checkout_provenance("mgh3326/agent-skills", 10, 1, H))

    def test_checkout_merge_sha_fails_closed_on_bad_or_ambiguous_prefix(self) -> None:
        checkout_sha = "e" * 40
        # Abbreviation that is not a prefix of the only candidate.
        self.assertIsNone(gate.checkout_merge_sha(checkout_log("f" * 9, checkout_sha)))
        # Tokens outside the 7..40 window are not announcements at all.
        for abbrev in ("e" * 6, "e" * 41, "E" * 9):
            with self.subTest(abbrev=abbrev[:10]):
                self.assertIsNone(gate.checkout_merge_sha(checkout_log(abbrev, checkout_sha)))
        # No announcement line at all.
        self.assertIsNone(gate.checkout_merge_sha(checkout_log(None, checkout_sha)))
        # A foreign announcement in the same window is ambiguous even beside a matching one.
        self.assertIsNone(gate.checkout_merge_sha(checkout_log("f" * 9, checkout_sha, extra_announces=[checkout_sha[:9]])))
        # Ambiguous: one 9-char abbreviation is a prefix of two different candidates.
        twin = "e" * 9 + "0" * 31
        self.assertIsNone(gate.checkout_merge_sha(two_checkout_log(checkout_sha[:9], checkout_sha, twin[:9], twin)))
        # Ambiguous: distinct announcements for distinct candidates in one log.
        other = "f" * 40
        self.assertIsNone(gate.checkout_merge_sha(two_checkout_log(checkout_sha[:9], checkout_sha, other[:9], other)))
        # A non-git command that merely mentions the phrase is not the checkout command,
        # even when its printed SHA shares the announced prefix (tester round-1 BLOCKER).
        forged = "abcdef0111111111111111111111111111111111"
        forge_log = (f"{CHECKOUT_STAMP}HEAD is now at abcdef0 Merge {H} into {B}\n"
                     f"{CHECKOUT_STAMP}[command]/usr/bin/printf '%s\\n' {forged} # git log -1 --format=%H\n"
                     f"ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:01Z {forged}\n")
        self.assertIsNone(gate.checkout_merge_sha(forge_log))
        # Other subcommands and trailing arguments are not the git-log command either.
        for command in ("/usr/bin/git checkout --progress --force .",
                        "git status",
                        "/usr/bin/legit log -1 --format=%H",
                        "/usr/bin/git log -1 --format=%H extra"):
            with self.subTest(command=command):
                self.assertIsNone(gate.checkout_merge_sha(checkout_log(checkout_sha[:9], checkout_sha, command=command)))
        # Records outside the checkout step cannot be the candidate, even an exact
        # verbatim echo of the real command (tester round-2 BLOCKER).
        for step in ("Run echo forged checkout record", "Run bash", "Post actions/checkout@v4", "Pre Run actions/checkout@v4"):
            with self.subTest(step=step):
                self.assertIsNone(gate.checkout_merge_sha(checkout_log("abcdef0", forged, step=step)))
        # An announce from another step does not corroborate the checkout output.
        foreign_step_announce = (
            "ubuntu-latest\tRun bash\t2026-09-25T07:00:00Z HEAD is now at " + checkout_sha[:9] + f" Merge {H} into {B}\n"
            f"{CHECKOUT_STAMP}[command]/usr/bin/git log -1 --format=%H\n"
            f"ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:01Z {checkout_sha}\n")
        self.assertIsNone(gate.checkout_merge_sha(foreign_step_announce))
        # The output line must come from the checkout step too.
        self.assertIsNone(gate.checkout_merge_sha(checkout_log(checkout_sha[:9], checkout_sha, out_step="Run echo forged")))

    def test_checkout_merge_sha_mutants_are_assertion_red(self) -> None:
        checkout_sha = "e" * 40
        fixed_nine = checkout_log(checkout_sha[:9], checkout_sha)
        only_seven = merge_precheck_mutant([("([0-9a-f]{7,40})", "([0-9a-f]{7})")])
        with self.assertRaises(AssertionError):
            self.assertEqual(checkout_sha, only_seven(fixed_nine))
        any_announce = merge_precheck_mutant([("not full.startswith(abbrev)", "False")])
        with self.assertRaises(AssertionError):
            self.assertIsNone(any_announce(checkout_log("f" * 9, checkout_sha)))
        optional_announce = merge_precheck_mutant([("not abbreviations", "False")])
        with self.assertRaises(AssertionError):
            self.assertIsNone(optional_announce(checkout_log(None, checkout_sha)))
        first_wins = merge_precheck_mutant([("return candidates[0] if len(candidates) == 1 else None", "return candidates[0]")])
        twin = "e" * 9 + "0" * 31
        with self.assertRaises(AssertionError):
            self.assertIsNone(first_wins(two_checkout_log(checkout_sha[:9], checkout_sha, twin[:9], twin)))
        loose_command = merge_precheck_mutant([(r"\[command\](?:\S*/git|git) log -1 --format=%H\s*$", r"\[command\].*git log -1 --format=%H")])
        forged = "abcdef0111111111111111111111111111111111"
        forge_log = (f"{CHECKOUT_STAMP}HEAD is now at abcdef0 Merge {H} into {B}\n"
                     f"{CHECKOUT_STAMP}[command]/usr/bin/printf '%s\\n' {forged} # git log -1 --format=%H\n"
                     f"ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:01Z {forged}\n")
        with self.assertRaises(AssertionError):
            self.assertIsNone(loose_command(forge_log))
        any_step = merge_precheck_mutant([("not CHECKOUT_STEP.search(line)", "False")])
        echo_forge_log = (f"{CHECKOUT_STAMP}HEAD is now at abcdef0 Merge {H} into {B}\n"
                          f"ubuntu-latest\tRun echo forge\t2026-09-25T07:00:00Z [command]/usr/bin/git log -1 --format=%H\n"
                          f"ubuntu-latest\tRun actions/checkout@v4\t2026-09-25T07:00:01Z {forged}\n")
        with self.assertRaises(AssertionError):
            self.assertIsNone(any_step(echo_forge_log))

    def test_missing_branch_protection_source_mutant_is_red(self) -> None:
        required = policy()
        actual = ci_canonical.evaluate_required_ci(required, "mgh3326/auto_trader", H, B, [], {}, None)
        self.assertEqual(("UNVERIFIED", "CI_BRANCH_PROTECTION_MISSING"), (actual["status"], actual["reason_code"]))
        source = (ROOT / "director/ci_canonical.py").read_text()
        start = source.index('    if "branch_protection" in workflows:')
        end = source.index("\n    observations:", start)
        namespace: dict = {"__name__": "ci_canonical_mutant"}
        exec(source[:start] + source[end:], namespace)
        mutant = namespace["evaluate_required_ci"](required, "mgh3326/auto_trader", H, B, [], {}, None)
        with self.assertRaises(AssertionError):
            self.assertEqual("CI_BRANCH_PROTECTION_MISSING", mutant["reason_code"])

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
        s = snapshot()
        s["ci_runs"] = []
        s["ci_jobs"] = {}
        assert_check(self, s, "G4", "UNVERIFIED", "CI_BASE_UNPROVEN")
        s = snapshot()
        s["ci_jobs"][10][0]["tested_merge_tree"] = OTHER
        assert_check(self, s, "G4", "UNVERIFIED", "CI_MERGE_TREE_MISMATCH")

    def test_actual_profile_differs_from_plan(self) -> None:
        _, check = resolve_profile("grok", policy(), actual_model="grok-4.6", actual_effort="xhigh")
        self.assertEqual("ACTUAL_MODEL_MISMATCH", check["reason_code"])
        _, check = resolve_profile("grok", policy(), actual_model="grok-4.7", actual_effort="medium")
        self.assertEqual("PROFILE_EFFORT_UNKNOWN", check["reason_code"])
        resolved, check = resolve_profile("grok", policy(), actual_model="grok-4.7", actual_effort="xhigh")
        self.assertEqual(("PASS", "S", "xhigh"), (check["status"], resolved["grade"], resolved["effort"]))

    def test_runtime_only_change_and_host_receipt(self) -> None:
        s = snapshot()
        s["repo"] = "mgh3326/auto_trader-operator"
        s["files"] = [{"filename": "runners/h1_pilot_runner.py", "status": "modified", "patch": "@@ -1 +1 @@\n+pass"}]
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_RECEIPT_MISSING")
        s["runtime_receipt"] = {"ref": {"path": "/tmp/host.json", "sha256": "1" * 64}, "data": {
            "kind": "host-runtime", "repo": s["repo"], "PR": 999, "H": H, "target": "NCP", "service": "ncp-operator-runners",
            "interpreter": "/usr/bin/python3.11", "version": "3.11.9", "exec_start": "/usr/bin/python3.11 /srv/auto-trader-operator/runners/h1_pilot_runner.py",
            "issuer": "operator-desk", "observed_at": "2026-09-25T07:30:00Z", "os": "linux", "arch": "x86_64",
            "lock_ref": "uv.lock@" + H, "dependencies_ref": "pyproject.toml@" + H, "proof_ref": "host-observation/1"}}
        assert_check(self, s, "G9", "PASS", "RUNTIME_HOST_OBSERVED")
        s["runtime_receipt"]["data"]["issuer"] = s["issuer"]
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_NOT_INDEPENDENT")
        source = (ROOT / "director/merge_precheck.py").read_text()
        guard = 'if not isinstance(data.get("issuer"), str) or data.get("issuer") in (None, "", snapshot.get("issuer")):'
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "merge_precheck_issuer_mutant"}
        exec(source.replace(guard, "if False:"), namespace)
        with self.assertRaises(AssertionError):
            self.assertEqual("UNVERIFIED", namespace["check_runtime"](s, policy())["status"])
        s["runtime_receipt"]["data"]["issuer"] = "operator-desk"
        s["runtime_receipt"]["data"]["exec_start"] = "echo /usr/bin/python3.11"
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_OBSERVATION_INCOMPLETE")
        s["runtime_receipt"]["data"]["exec_start"] = "/usr/bin/python3.11 /srv/auto-trader-operator/runners/h1_pilot_runner.py"
        s["runtime_receipt"]["data"]["lock_ref"] = "uv.lock@old"
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_OBSERVATION_INCOMPLETE")
        s["runtime_receipt"]["data"]["lock_ref"] = "uv.lock@" + H
        s["runtime_receipt"]["data"]["exec_start"] = "python3 --version"
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_OBSERVATION_INCOMPLETE")
        s["runtime_receipt"]["data"]["issuer"] = ["operator-desk"]
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_NOT_INDEPENDENT")
        s["runtime_receipt"]["data"]["issuer"] = "operator-desk"
        s["runtime_receipt"]["data"]["exec_start"] = "/usr/bin/python3.11 /srv/auto-trader-operator/runners/h1_pilot_runner.py"
        s["runtime_receipt"]["data"]["lock_ref"] = ["uv.lock@" + H]
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_OBSERVATION_INCOMPLETE")

    def test_nonstring_observation_and_ledger_time_fail_closed(self) -> None:
        s = snapshot()
        s["repo"] = "mgh3326/auto_trader-operator"
        s["files"] = [{"filename": "runners/h1.py", "status": "modified", "patch": "@@ -1 +1 @@\n+changed"}]
        s["runtime_receipt"] = {"ref": {"path": "/tmp/host.json", "sha256": "1" * 64}, "data": {
            "kind": "host-runtime", "repo": s["repo"], "PR": s["PR"], "H": H, "target": "NCP",
            "service": "ncp-operator-runners", "interpreter": "/usr/bin/python3.11",
            "issuer": "independent", "observed_at": None}}
        assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_TIME_INVALID")
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            events = home / "work/herdr-inbox/jobs/task/events"
            events.mkdir(parents=True)
            (events / "00003-job.spawned.json").write_text(json.dumps({"created_at": None, "job_id": "task"}))
            receipts = home / "receipts"
            receipts.mkdir()
            with patch.object(gate.Path, "home", return_value=home), patch.object(gate, "gh_api", return_value={"total_count": 0}), patch.object(gate, "gh_pages", return_value=[]):
                result = gate.audit(receipts, {"ci": {"mgh3326/agent-skills": {"ci": ["test"]}}}, "2026-09-25T06:00:00Z")
            self.assertEqual(("UNVERIFIED", "AUDIT_LEDGER_LOOKUP_FAILED"), (result["status"], result["reason_code"]))

    def test_runtime_policy_globs_cover_dependency_and_shell_script(self) -> None:
        for path in ("requirements.txt", "scripts/start.sh"):
            with self.subTest(path=path):
                s = snapshot()
                s["repo"] = "mgh3326/auto_trader-operator"
                s["files"] = [{"filename": path, "status": "modified", "patch": "@@ -1 +1 @@\n+changed"}]
                assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_RECEIPT_MISSING")
        for path in ("Scripts/start.sh", "lib/requirements.txt"):
            with self.subTest(unknown_path=path):
                s = snapshot()
                s["repo"] = "mgh3326/auto_trader-operator"
                s["files"] = [{"filename": path, "status": "modified", "patch": "@@ -1 +1 @@\n+changed"}]
                assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_TARGET_UNKNOWN")

    def test_lookup_process_failures_become_unverified_inputs(self) -> None:
        for failure in (subprocess.TimeoutExpired(["gh"], 1), FileNotFoundError("gh")):
            with self.subTest(failure=type(failure).__name__), patch.object(gate.subprocess, "run", side_effect=failure):
                with self.assertRaisesRegex(RuntimeError, "LOOKUP_TIMEOUT|LOOKUP_UNAVAILABLE"):
                    gate.run_json(["gh", "api", "repos/example/example"])

    def test_audit_counts_nonpassing_and_reused_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "work/herdr-inbox/jobs").mkdir(parents=True)
            receipt_dir = root / "receipts"
            receipt_dir.mkdir()
            receipt = {"action_id": "id1", "kind": "merge", "repo": "mgh3326/agent-skills", "PR": 999, "H": H,
                       "time": "2026-09-25T07:00:00Z", "checks": {f"G{i}": {"status": "PASS"} for i in range(1, 11)}}
            receipt["checks"]["G3"] = {"status": "UNVERIFIED"}
            target = receipt_dir / "id1.json"
            target.write_text(json.dumps(receipt))
            api = lambda endpoint: ({"total_count": 1} if endpoint.startswith("search/issues") else
                                    {"number": 999, "merged_at": "2026-09-25T08:00:00Z", "head": {"sha": H}})
            with patch.object(gate.Path, "home", return_value=root), patch.object(gate, "gh_api", side_effect=api), patch.object(gate, "gh_pages", return_value=[{"number": 999}]):
                def audited() -> dict:
                    return gate.audit(receipt_dir, {"ci": {"mgh3326/agent-skills": {"ci": ["test"]}}}, "2026-09-25T06:00:00Z")
                first = audited()
                self.assertEqual(("FAIL", "AUDIT_BYPASS_DETECTED", 1), (first["status"], first["reason_code"], first["receipt_not_pass"]))
                receipt["checks"]["G3"] = {"status": "PASS"}
                target.write_text(json.dumps(receipt))
                self.assertEqual(("PASS", 0), (audited()["status"], audited()["receipt_not_pass"]))
                (receipt_dir / "copy.json").write_text(json.dumps(receipt))
                self.assertEqual(("FAIL", 1), (audited()["status"], audited()["reused_receipt"]))
                (receipt_dir / "copy.json").unlink()
                receipt["time"] = "2026-09-25T09:00:00Z"
                target.write_text(json.dumps(receipt))
                self.assertEqual(1, audited()["receipt_after_action"])
                del receipt["action_id"]
                target.write_text(json.dumps(receipt))
                self.assertEqual(("UNVERIFIED", "AUDIT_RECEIPT_INVALID"),
                                 (audited()["status"], audited()["reason_code"]))
                target.unlink()
                self.assertEqual(("FAIL", 1), (audited()["status"], audited()["no_receipt"]))

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
            {"kind": "job.spawned", "job_id": "task727-tester", "label": "tester-grok", "pane_id": "synthetic-pane"},
            {"kind": "job.completed", "job_id": "task727-tester", "report_path": "/tmp/tester-report.md", "report_sha256": "e" * 64}]
        s["job_events"][1] = {"kind": "job.joined", "pr": s["pr_url"], "head": H, "report_path": "/tmp/task727-builder-report.md"}
        assert_check(self, s, "G1", "PASS", "TESTER_PASS_BOUND")
        assert_check(self, s, "G8", "PASS", "QUEUE_JOIN_CONSISTENT")
        s["tester_events"][1]["report_sha256"] = "0" * 64
        assert_check(self, s, "G1", "UNVERIFIED", "TESTER_REPORT_CHANGED_AFTER_COMPLETION")
        del s["tester_events"][1]["report_sha256"]
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

    def test_truncated_patch_is_unverified_before_scanning(self) -> None:
        files = [{"filename": "src/example.py", "patch": "@@ -0,0 +1 @@\n+safe", "additions": 2, "deletions": 0}]
        scan = gate.scan_patches(files, B, H)
        self.assertFalse(scan["complete"])
        s = snapshot()
        s["files"], s["scan"] = files, scan
        assert_check(self, s, "G5", "UNVERIFIED", "DIFF_TRUNCATED_OR_UNBOUND")

    def test_added_line_starting_with_two_plus_signs_is_scanned(self) -> None:
        patch_text = "@@ -0,0 +1,2 @@\n+ordinary line\n+++api_" + "key=EXAMPLEKEY123456"
        files = [{"filename": "README.md", "patch": patch_text,
                  "additions": 2, "deletions": 0}]
        responses = [subprocess.CompletedProcess([], 0, "8.30.1\n", ""),
                     subprocess.CompletedProcess([], 0, "[]", "")]
        with patch.object(gate.subprocess, "run", side_effect=responses):
            scan = gate.scan_patches(files, B, H)
        self.assertTrue(scan["complete"])
        self.assertIn({"location": "README.md:2", "class": "credential_assignment"}, scan["hits"])
        source = (ROOT / "director/merge_precheck.py").read_text()
        guard = 'elif line.startswith("+"):'
        self.assertEqual(1, source.count(guard))
        namespace: dict = {"__name__": "merge_precheck_scan_mutant"}
        exec(source.replace(guard, 'elif line.startswith("+") and not line.startswith("+++"):'), namespace)
        with self.assertRaises(AssertionError):
            self.assertIn({"location": "README.md:2", "class": "credential_assignment"},
                          namespace["scan_patches"](files, B, H)["hits"])
        s = snapshot()
        s["files"], s["scan"] = files, scan
        assert_check(self, s, "G5", "FAIL", "LEAK_PATTERN_HIT")

    def test_risks_section_and_surface_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "builder.md"
            path.write_text(f"HEAD: {H}\n## RISKS\n- host version unknown\n## Result\n")
            s = snapshot()
            s["builder_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G7", "UNVERIFIED", "RISK_UNDISPOSED")
            path.write_text(f"HEAD: {H}\n## RISKS\n- no risks were ruled out; credential leak remains\n")
            s["builder_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G7", "UNVERIFIED", "RISK_UNDISPOSED")
        s = snapshot()
        s["files"] = [{"filename": "runner.py", "status": "modified", "patch": "@@ -1 +1 @@\n+ExecStart=/usr/bin/python3.11"}]
        s["surface_class"] = "policy_or_config"
        assert_check(self, s, "G6", "UNVERIFIED", "SURFACE_CLASS_UNBOUND")

    def test_markdown_blocker_heading_requires_disposition(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tester.md"
            path.write_text(f"HEAD: {H}\n## BLOCKER — unresolved defect\n")
            s = snapshot()
            s["tester_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G7", "FAIL", "BLOCKER_UNDISPOSED")
            path.write_text(f"HEAD: {H}\n## BLOCKER — resolved defect disposition_ref: fix-123\n")
            s["tester_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G7", "PASS", "ISSUES_DISPOSED")

    def test_indented_atx_brief_blocker_and_risks_are_authoritative(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tester.md"
            common = (f"TASK: 727\nREPO: mgh3326/agent-skills\nPR: 999\n"
                      f"TESTER_JOB: task727-tester\nTESTER_SESSION: tester-grok\n")
            path.write_text(common + f"VERDICT: BLOCKER @{H}\n # Brief\nVERDICT: PASS @{H}\n")
            s = snapshot()
            s["tester_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G1", "FAIL", "TESTER_BLOCKER")
            source = (ROOT / "director/merge_precheck.py").read_text()
            heading = r"^ {0,3}(#{1,6})[ \t]+(.+)$"
            self.assertEqual(1, source.count(heading))
            namespace: dict = {"__name__": "merge_precheck_heading_mutant"}
            exec(source.replace(heading, r"^(#{1,6})[ \t]+(.+)$"), namespace)
            mutant = namespace["parse_report"](str(path))
            with self.assertRaises(AssertionError):
                self.assertEqual("BLOCKER", mutant["verdict"])
            for indent in (" ", "   "):
                path.write_text(common + f"VERDICT: PASS @{H}\n{indent}# BLOCKER — unresolved defect\n")
                s["tester_report"] = gate.parse_report(str(path))
                assert_check(self, s, "G7", "FAIL", "BLOCKER_UNDISPOSED")
                path.write_text(common + f"VERDICT: PASS @{H}\n{indent}# RISKS\n- host version unknown\n")
                s["tester_report"] = gate.parse_report(str(path))
                assert_check(self, s, "G7", "UNVERIFIED", "RISK_UNDISPOSED")

    def test_sha256_spellings_and_line_break_require_receipt(self) -> None:
        for body in ("SHA-256: ", "sha256sum ", "sha256:\n", ""):
            with self.subTest(body=body):
                s = snapshot()
                s["pr_body"] = body + "e" * 64
                assert_check(self, s, "G10", "UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING")
                with patch.object(gate, "ARTIFACT_SHA", re.compile(r"(?i)\b(?:artifact|sha256)\b[^\n]{0,100}([0-9a-f]{64})")):
                    with self.assertRaises(AssertionError):
                        assert_check(self, s, "G10", "UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING")

    def test_migration_runtime_and_casefolded_artifact(self) -> None:
        for path in ("db/migrate/001_init.sql", "db/migrate.sql", "foo/alembic/x.sql"):
            s = snapshot()
            s["files"] = [{"filename": path, "status": "modified", "patch": "@@ -1 +1 @@\n+changed"}]
            assert_check(self, s, "G6", "UNVERIFIED", "SURFACE_CLASS_UNBOUND")
        for path in ("foo/scripts/start.sh", "poetry.lock", "db/migrate/001_init.sql"):
            s = snapshot()
            s["files"] = [{"filename": path, "status": "modified", "patch": "@@ -1 +1 @@\n+changed"}]
            assert_check(self, s, "G9", "UNVERIFIED", "RUNTIME_TARGET_UNKNOWN")
        s = snapshot()
        s["files"] = [{"filename": "build/Foo.PYC", "status": "added", "patch": "@@ -0,0 +1 @@\n+changed"}]
        assert_check(self, s, "G5", "FAIL", "BUILD_ARTIFACT_ADDED")

    def test_structured_verdict_rejects_malformed_issue_list(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "tester.json"
            path.write_text(json.dumps({"kind": "tester-verdict", "verdict": "PASS", "H": H, "issues": "BLOCKER"}))
            s = snapshot()
            s["tester_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G1", "UNVERIFIED", "REPORT_SCHEMA_INVALID")
            assert_check(self, s, "G7", "UNVERIFIED", "ISSUE_REPORT_MISSING")
            path.write_text(json.dumps({"kind": "tester-verdict", "verdict": "PASS", "H": H, "issues": [],
                                        "task": 727, "repo": "mgh3326/agent-skills", "pr": 999,
                                        "tester_job": "task727-tester", "tester_session": ["tester-grok"]}))
            s["tester_report"] = gate.parse_report(str(path))
            assert_check(self, s, "G1", "UNVERIFIED", "REPORT_SCHEMA_INVALID")
            path.write_text(json.dumps({"kind": "tester-verdict", "verdict": "PASS", "H": H, "issues": [],
                                        "task": 727, "repo": "mgh3326/agent-skills", "pr": 999,
                                        "tester_job": "task727-tester", "tester_session": "tester-grok"}))
            s["tester_report"] = gate.parse_report(str(path))
            s["tester_events"][1]["payload"]["report_path"] = str(path.resolve())
            s["tester_events"][1]["payload"]["report_sha256"] = s["tester_report"]["ref"]["sha256"]
            assert_check(self, s, "G1", "PASS", "TESTER_PASS_BOUND")

    def test_stale_policy_still_writes_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            raw = json.loads((ROOT / "director/gate_policy.json").read_text())
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
        expected = {
            "mgh3326/auto_trader": ("UNVERIFIED", {
                "G1": ("UNVERIFIED", "REPORT_MISSING"), "G2": ("PASS", "PR_HEAD_CURRENT"),
                "G3": ("UNVERIFIED", "CI_BASE_MOVED"), "G4": ("UNVERIFIED", "BASE_BEHIND"),
                "G5": ("PASS", "SCAN_NO_HITS"), "G6": ("UNVERIFIED", "SURFACE_CLASS_UNBOUND"),
                "G7": ("UNVERIFIED", "ISSUE_REPORT_MISSING"), "G8": ("UNVERIFIED", "TASK_STATE_MISMATCH"),
                "G9": ("UNVERIFIED", "RUNTIME_TARGET_UNKNOWN"), "G10": ("N/A", "ARTIFACT_HASH_NOT_CITED"),
            }),
            "mgh3326/panewire": ("FAIL", {
                "G1": ("UNVERIFIED", "REPORT_MISSING"), "G2": ("PASS", "PR_HEAD_CURRENT"),
                "G3": ("UNVERIFIED", "CI_BASE_MOVED"), "G4": ("UNVERIFIED", "BASE_BEHIND"),
                "G5": ("FAIL", "LEAK_PATTERN_HIT"), "G6": ("PASS", "SURFACE_FLAGS_RECORDED"),
                "G7": ("UNVERIFIED", "ISSUE_REPORT_MISSING"), "G8": ("UNVERIFIED", "TASK_STATE_MISMATCH"),
                "G9": ("N/A", "RUNTIME_SURFACE_ABSENT"), "G10": ("N/A", "ARTIFACT_HASH_NOT_CITED"),
            }),
            "mgh3326/scopefuel": ("UNVERIFIED", {
                "G1": ("UNVERIFIED", "REPORT_MISSING"), "G2": ("PASS", "PR_HEAD_CURRENT"),
                "G3": ("UNVERIFIED", "CI_BASE_MOVED"), "G4": ("UNVERIFIED", "BASE_BEHIND"),
                "G5": ("PASS", "SCAN_NO_HITS"), "G6": ("PASS", "SURFACE_FLAGS_RECORDED"),
                "G7": ("UNVERIFIED", "ISSUE_REPORT_MISSING"), "G8": ("UNVERIFIED", "TASK_STATE_MISMATCH"),
                "G9": ("UNVERIFIED", "RUNTIME_TARGET_UNKNOWN"), "G10": ("N/A", "ARTIFACT_HASH_NOT_CITED"),
            }),
        }
        for replay in source["replays"]:
            with self.subTest(repo=replay["repo"]):
                self.assertEqual("MERGED", replay["actual_gate"])
                overall, checks = expected[replay["repo"]]
                self.assertEqual(overall, replay["tool_result"])
                self.assertEqual(set(checks), set(replay["tool_checks"]))
                for key, (status, code) in checks.items():
                    self.assertEqual((status, code),
                                     (replay["tool_checks"][key]["status"], replay["tool_checks"][key]["reason_code"]),
                                     f"{replay['repo']} {key}")

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
