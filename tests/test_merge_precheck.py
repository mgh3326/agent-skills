"""Contract fixtures and assertion-RED mutants for the shadow merge gate."""

from __future__ import annotations

import copy
import json
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
            for field, value, reason in (("runtime", [], "POLICY_RUNTIME_UNKNOWN"),
                                         ("artifact_paths", [], "POLICY_ARTIFACT_PATHS_UNKNOWN"),
                                         ("effective_at", {}, "POLICY_TIME_INVALID")):
                invalid = json.loads(path.read_text())
                invalid[field] = value
                target.write_text(json.dumps(invalid))
                with self.assertRaisesRegex(PolicyError, reason):
                    load_policy(target, datetime(2026, 9, 26, tzinfo=timezone.utc))

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
        s = snapshot()
        s["ci_jobs"][10] = s["ci_jobs"][10][:1]
        s["ci_jobs"][10][0]["conclusion"] = "failure"
        assert_check(self, s, "G3", "FAIL", "CI_FAILED")

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
        catalog = {"grok": {"provider": "xai", "model": "grok-4.7", "effort": "xhigh", "grade": "S"}}
        with self.assertRaisesRegex(PolicyError, "PROFILE_ACTUAL_MISMATCH"):
            resolve_profile("grok", catalog, {"provider": "xai", "model": "grok-4.7", "effort": "high"})
        with self.assertRaisesRegex(PolicyError, "PROFILE_ACTUAL_MISMATCH"):
            resolve_profile("grok", catalog, {"provider": "xai", "model": "grok-4.7", "effort": "xhigh", "grade": "A+"})
        with self.assertRaisesRegex(PolicyError, "PROFILE_ACTUAL_MISMATCH"):
            resolve_profile("grok", catalog, {"provider": "xai", "model": "grok-4.7", "effort": "xhigh"})

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
        guard = 'if data.get("issuer") in (None, "", snapshot.get("issuer")):'
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
                                        "tester_job": "task727-tester", "tester_session": "tester-grok"}))
            s["tester_report"] = gate.parse_report(str(path))
            s["tester_events"][1]["payload"]["report_path"] = str(path.resolve())
            s["tester_events"][1]["payload"]["report_sha256"] = s["tester_report"]["ref"]["sha256"]
            assert_check(self, s, "G1", "PASS", "TESTER_PASS_BOUND")

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
        expected = {
            "mgh3326/auto_trader": ("UNVERIFIED", {
                "G1": ("UNVERIFIED", "REPORT_MISSING"), "G2": ("PASS", "PR_HEAD_CURRENT"),
                "G3": ("UNVERIFIED", "CI_BASE_UNBOUND"), "G4": ("UNVERIFIED", "BASE_BEHIND"),
                "G5": ("PASS", "SCAN_NO_HITS"), "G6": ("UNVERIFIED", "SURFACE_CLASS_UNBOUND"),
                "G7": ("UNVERIFIED", "ISSUE_REPORT_MISSING"), "G8": ("UNVERIFIED", "QUEUE_LOOKUP_FAILED"),
                "G9": ("UNVERIFIED", "RUNTIME_TARGET_UNKNOWN"), "G10": ("N/A", "ARTIFACT_HASH_NOT_CITED"),
            }),
            "mgh3326/panewire": ("FAIL", {
                "G1": ("UNVERIFIED", "REPORT_MISSING"), "G2": ("PASS", "PR_HEAD_CURRENT"),
                "G3": ("UNVERIFIED", "CI_BASE_UNBOUND"), "G4": ("UNVERIFIED", "BASE_BEHIND"),
                "G5": ("FAIL", "LEAK_PATTERN_HIT"), "G6": ("PASS", "SURFACE_FLAGS_RECORDED"),
                "G7": ("UNVERIFIED", "ISSUE_REPORT_MISSING"), "G8": ("UNVERIFIED", "QUEUE_LOOKUP_FAILED"),
                "G9": ("N/A", "RUNTIME_SURFACE_ABSENT"), "G10": ("N/A", "ARTIFACT_HASH_NOT_CITED"),
            }),
            "mgh3326/scopefuel": ("UNVERIFIED", {
                "G1": ("UNVERIFIED", "REPORT_MISSING"), "G2": ("PASS", "PR_HEAD_CURRENT"),
                "G3": ("UNVERIFIED", "CI_BASE_UNBOUND"), "G4": ("UNVERIFIED", "BASE_BEHIND"),
                "G5": ("PASS", "SCAN_NO_HITS"), "G6": ("PASS", "SURFACE_FLAGS_RECORDED"),
                "G7": ("UNVERIFIED", "ISSUE_REPORT_MISSING"), "G8": ("UNVERIFIED", "QUEUE_LOOKUP_FAILED"),
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
