"""Shadow merge gate. Reads evidence; writes only a JSON receipt.

Run: python3 director/merge_precheck.py mgh3326/agent-skills 144 --task 727
     --job JOB --tester-report PATH --builder-report PATH [--receipt-dir DIR]
Audit: python3 director/merge_precheck.py audit [--receipt-dir DIR] [--since ISO]

The receipt is detection evidence. This command does not merge, spawn, change
queue state, or verify any post-merge binary hash. A caller must compare H and
B again immediately before acting. The printed merge command pins H, but
GitHub CLI's --match-head-commit does not atomically pin the base branch.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

from ci_canonical import evaluate_required_ci
from gate_common import POLICY_PATH, PolicyError, file_ref, load_policy, sha256_bytes, write_receipt


VERSION = "merge-precheck/1.0.0"
SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
VERDICT = re.compile(r"^VERDICT: (PASS|BLOCKER) @([0-9a-f]{40})\s*$")
META = re.compile(r"^(TASK|REPO|PR|TESTER_JOB|TESTER_SESSION|HEAD|OWNER|JOIN):\s*(.+?)\s*$")
DISPOSITION = re.compile(r"\bdisposition(?:_ref)?:\s*([^\s,;]+)", re.I)
ISSUE = re.compile(r"^\s*(?:[-*]\s*)?(?:\*\*)?(BLOCKER|RISK)(?:\*\*)?(?:[- ]\d+)?\s*(?::|[—–-])\s*(.*)$", re.I)
ARTIFACT_SHA = re.compile(r"(?i)\b(?:artifact|binary|image|deploy|sha256)\b[^\n]{0,100}\b([0-9a-f]{64})\b")
SENSITIVE = {
    "private_address": re.compile(r"\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|192\.168\.(?:\d{1,3}\.)\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.(?:\d{1,3}\.)\d{1,3})\b"),
    "pane_identifier": re.compile(r"\bw[A-Za-z0-9]+:p[A-Za-z0-9]+\b"),
    "credential_assignment": re.compile(r"(?i)\b(?:api[_-]?key|secret|password|token)\s*[:=]\s*['\"]?\S{12,}"),
}


def result(status: str, reason_code: str, **details: Any) -> dict[str, Any]:
    return {"status": status, "reason_code": reason_code, **details}


def iso_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError("timezone required")
    return dt.astimezone(timezone.utc)


def run_json(argv: list[str], timeout: int = 30) -> Any:
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("LOOKUP_TIMEOUT") from exc
    except OSError as exc:
        raise RuntimeError("LOOKUP_UNAVAILABLE") from exc
    if completed.returncode:
        raise RuntimeError("LOOKUP_FAILED")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("LOOKUP_INVALID_JSON") from exc


def gh_api(endpoint: str) -> Any:
    return run_json(["gh", "api", endpoint])


def gh_pages(endpoint: str, key: str | None = None, limit: int = 20) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    sep = "&" if "?" in endpoint else "?"
    for page in range(1, limit + 1):
        data = gh_api(f"{endpoint}{sep}per_page=100&page={page}")
        items = data.get(key) if key else data
        if not isinstance(items, list):
            raise RuntimeError("LOOKUP_INVALID_PAGE")
        output.extend(items)
        if len(items) < 100:
            return output
    raise RuntimeError("LOOKUP_TRUNCATED")


def parse_report(path: str | None, expected_hash: str | None = None) -> dict[str, Any]:
    if not path:
        return {"error": "REPORT_MISSING"}
    try:
        source = Path(path).expanduser().resolve()
        raw = source.read_bytes()
        ref = {"path": str(source), "sha256": sha256_bytes(raw)}
        if expected_hash and ref["sha256"] != expected_hash:
            return {"error": "REPORT_HASH_MISMATCH", "ref": ref}
        content = raw.decode("utf-8")
    except (OSError, UnicodeError):
        return {"error": "REPORT_UNREADABLE"}
    try:
        structured = json.loads(content)
    except json.JSONDecodeError:
        structured = None
    if isinstance(structured, dict) and structured.get("kind") == "tester-verdict":
        verdict = structured.get("verdict")
        H = structured.get("H")
        issues = structured.get("issues", [])
        if verdict not in {"PASS", "BLOCKER"} or not isinstance(H, str) or not SHA.fullmatch(H) or not isinstance(issues, list) or any(
            not isinstance(issue, dict) or issue.get("class") not in {"BLOCKER", "RISK"} or not isinstance(issue.get("disposition_ref", ""), str)
            for issue in issues
        ):
            return {"error": "REPORT_SCHEMA_INVALID", "ref": ref}
        metadata = {key: structured.get(key.lower()) for key in ("TASK", "REPO", "PR", "TESTER_JOB", "TESTER_SESSION")}
        return {"ref": ref, "verdict": verdict, "H": H, "metadata": metadata, "issues": issues, "text": content}
    fence: tuple[str, int] | None = None
    html_comment = False
    brief_level: int | None = None
    last = None
    metadata: dict[str, str] = {}
    issues: list[dict[str, str]] = []
    risks_section = False
    for line in content.splitlines():
        stripped = line.strip()
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence is not None:
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= fence[1] and not marker.group(2).strip():
                fence = None
            continue
        if marker:
            fence = (marker.group(1)[0], len(marker.group(1)))
            continue
        if html_comment:
            if "-->" in line:
                html_comment = False
            continue
        if "<!--" in line:
            html_comment = "-->" not in line.split("<!--", 1)[1]
            continue
        heading = re.match(r"^(#{1,6})\s+(.+)$", line)
        if heading:
            level = len(heading.group(1))
            if brief_level is not None and (brief_level == 0 or level <= brief_level):
                brief_level = None
            if re.search(r"\b(?:brief|prompt|instructions|quoted report)\b", heading.group(2), re.I):
                brief_level = level
            risks_section = bool(re.match(r"^RISKS\b", heading.group(2).strip(), re.I))
            if brief_level is None:
                issue = ISSUE.match(heading.group(2))
                if issue:
                    ref_match = DISPOSITION.search(issue.group(2))
                    issues.append({"class": issue.group(1).upper(), "disposition_ref": ref_match.group(1) if ref_match else ""})
            continue
        if re.match(r"^\s*(?:brief|prompt|instructions):\s*$", line, re.I):
            brief_level = 0
            continue
        if brief_level is not None:
            continue
        if re.match(r"^\s*>", line):
            continue
        match = VERDICT.fullmatch(line)
        if match:
            last = match.groups()
            continue
        m = META.fullmatch(line)
        if m:
            metadata[m.group(1)] = m.group(2)
        issue = ISSUE.match(line)
        if issue:
            ref_match = DISPOSITION.search(issue.group(2))
            issues.append({"class": issue.group(1).upper(), "disposition_ref": ref_match.group(1) if ref_match else ""})
        elif risks_section and re.match(r"^\s*[-*]\s+", line):
            bullet = re.sub(r"^\s*[-*]\s+", "", line).strip()
            if not re.fullmatch(r"(?:none|no risks|0 risks)[.!]?", bullet, re.I):
                ref_match = DISPOSITION.search(line)
                issues.append({"class": "RISK", "disposition_ref": ref_match.group(1) if ref_match else ""})
    return {"ref": ref, "verdict": last[0] if last else None, "H": last[1] if last else metadata.get("HEAD"),
            "metadata": metadata, "issues": issues, "text": content}


def check_reports(snapshot: dict[str, Any]) -> dict[str, Any]:
    report = snapshot.get("tester_report", {})
    H = snapshot.get("H")
    if report.get("error"):
        return result("UNVERIFIED", report["error"])
    if report.get("verdict") is None:
        return result("UNVERIFIED", "TESTER_VERDICT_MISSING", report=report.get("ref"))
    if report.get("verdict") == "BLOCKER":
        return result("FAIL", "TESTER_BLOCKER", report=report.get("ref"))
    if report.get("verdict") != "PASS":
        return result("UNVERIFIED", "TESTER_VERDICT_INVALID", report=report.get("ref"))
    if report.get("H") != H:
        return result("FAIL", "TESTER_HEAD_MISMATCH", report=report.get("ref"))
    metadata = report.get("metadata", {})
    expected = {"TASK": str(snapshot.get("task")), "REPO": snapshot.get("repo"), "PR": str(snapshot.get("PR"))}
    if any(str(metadata.get(key, "")).lstrip("#") != str(value).lstrip("#") for key, value in expected.items()):
        return result("UNVERIFIED", "TESTER_BINDING_MISSING", report=report.get("ref"))
    if not metadata.get("TESTER_JOB") or not metadata.get("TESTER_SESSION"):
        return result("UNVERIFIED", "TESTER_IDENTITY_MISSING", report=report.get("ref"))
    events = snapshot.get("tester_events")
    if not isinstance(events, list):
        return result("UNVERIFIED", "TESTER_JOB_LOOKUP_FAILED", report=report.get("ref"))
    if any(event.get("job_id") != metadata["TESTER_JOB"] for event in events):
        return result("UNVERIFIED", "TESTER_JOB_MISMATCH")
    spawned = [event.get("payload", event) for event in events if event.get("kind") == "job.spawned"]
    completed = [event.get("payload", event) for event in events if event.get("kind") == "job.completed"]
    if not spawned or metadata["TESTER_SESSION"] not in {spawned[-1].get("label"), spawned[-1].get("pane_id")}:
        return result("UNVERIFIED", "TESTER_SESSION_MISMATCH")
    if not completed or completed[-1].get("report_path") != report.get("ref", {}).get("path"):
        return result("UNVERIFIED", "TESTER_JOB_INCOMPLETE")
    if completed[-1].get("report_sha256") and completed[-1]["report_sha256"] != report.get("ref", {}).get("sha256"):
        return result("UNVERIFIED", "TESTER_REPORT_CHANGED_AFTER_COMPLETION")
    eligible = snapshot.get("eligibility_receipt")
    if snapshot.get("tier") == "T3" and not eligible:
        return result("UNVERIFIED", "ELIGIBILITY_RECEIPT_MISSING")
    if eligible:
        if eligible.get("error"):
            return result("UNVERIFIED", eligible["error"])
        data = eligible.get("data", {})
        if data.get("kind") != "spawn" or data.get("task") != snapshot.get("task") or data.get("repo") != snapshot.get("repo") or data.get("PR") != snapshot.get("PR") or data.get("H") != H or data.get("tester_job") != metadata["TESTER_JOB"]:
            return result("UNVERIFIED", "ELIGIBILITY_BINDING_MISMATCH")
        eligible_checks = data.get("checks", {})
        if not eligible_checks or any(check.get("status") not in ("PASS", "N/A") for check in eligible_checks.values()):
            return result("FAIL" if any(check.get("status") == "FAIL" for check in eligible_checks.values()) else "UNVERIFIED", "ELIGIBILITY_NOT_PASS")
    return result("PASS", "TESTER_PASS_BOUND", report=report["ref"], tester_job=metadata["TESTER_JOB"], tester_session=metadata["TESTER_SESSION"], eligibility=eligible.get("ref") if eligible else None)


def check_head(snapshot: dict[str, Any]) -> dict[str, Any]:
    H = snapshot.get("H")
    if not isinstance(H, str) or not SHA.fullmatch(H):
        return result("UNVERIFIED", "PR_HEAD_LOOKUP_FAILED")
    if snapshot.get("expected_H") and snapshot["expected_H"] != H:
        return result("FAIL", "PR_HEAD_MOVED")
    if snapshot.get("head_ref_sha") != H:
        return result("UNVERIFIED", "PR_HEAD_REF_MISMATCH")
    return result("PASS", "PR_HEAD_CURRENT", H=H)


def check_base(snapshot: dict[str, Any], ci: dict[str, Any]) -> dict[str, Any]:
    B, H = snapshot.get("B"), snapshot.get("H")
    if not isinstance(B, str) or not SHA.fullmatch(B) or snapshot.get("base_ref_sha") != B:
        return result("UNVERIFIED", "BASE_LOOKUP_FAILED")
    compare = snapshot.get("head_to_base")
    if not isinstance(compare, dict) or not isinstance(compare.get("ahead_by"), int):
        return result("UNVERIFIED", "BASE_COMPARE_FAILED")
    if compare["ahead_by"] > 0:
        return result("UNVERIFIED", "BASE_BEHIND", behind=compare["ahead_by"])
    M = snapshot.get("M")
    if not isinstance(M, str) or not SHA.fullmatch(M) or set(snapshot.get("merge_parents", [])) != {B, H}:
        return result("UNVERIFIED", "TRIAL_MERGE_UNBOUND")
    if any(job.get("base_sha") != B for job in ci.get("jobs", [])):
        return result("UNVERIFIED", "BASE_AFTER_CI_UNKNOWN")
    if ci.get("status") != "PASS" or not ci.get("jobs"):
        return result("UNVERIFIED", "CI_BASE_UNPROVEN")
    return result("PASS", "BASE_AND_MERGE_CURRENT", behind=0, M=M,
                  merge_command=f"gh pr merge {snapshot['PR']} -R {snapshot['repo']} --merge --match-head-commit {H}")


def classify_surface(files: list[dict[str, Any]], repo: str, policy: dict[str, Any]) -> dict[str, Any]:
    flags: list[str] = []
    for file in files:
        path = file.get("filename", "")
        low = path.lower()
        if "migration" in low or low.startswith("alembic/"):
            flags.append("migration")
        if low.startswith(("config/", "deploy/", ".github/")) or any(word in low for word in ("settings", "config", "requirements")) or low in {"pyproject.toml", "uv.lock", "dockerfile"} or low.endswith((".service", ".service.example", ".toml", ".yaml", ".yml")):
            flags.append("config")
        if any(x in low for x in ("policy", "skill.md", "gate-")):
            flags.append("policy")
        patch = file.get("patch", "")
        if isinstance(patch, str) and any(re.match(r"^\+(?:ExecStart=|requires-python\s*=|FROM\s+)", line, re.I) for line in patch.splitlines()):
            flags.append("config")
    return {"flags": sorted(set(flags)), "surface_class": "policy_or_config" if flags else "code_or_docs"}


def check_diff(snapshot: dict[str, Any], policy: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    files = snapshot.get("files")
    scan = snapshot.get("scan")
    if not isinstance(files, list) or not isinstance(scan, dict):
        return result("UNVERIFIED", "DIFF_LOOKUP_FAILED"), {"flags": [], "surface_class": "unknown"}
    surface = classify_surface(files, snapshot["repo"], policy)
    if len(files) >= 300 or not scan.get("complete") or scan.get("H") != snapshot.get("H") or scan.get("B") != snapshot.get("B"):
        return result("UNVERIFIED", "DIFF_TRUNCATED_OR_UNBOUND"), surface
    if not scan.get("scanner") or not scan.get("version") or scan.get("exit_code") not in (0, 1):
        return result("UNVERIFIED", "SCANNER_FAILED"), surface
    for f in files:
        path = f.get("filename", "")
        if f.get("status") == "added" and any(fnmatch.fnmatch(path, pattern) or fnmatch.fnmatch(path, "*/" + pattern) for pattern in policy.get("artifact_paths", [])):
            return result("FAIL", "BUILD_ARTIFACT_ADDED", hits=[{"location": path, "class": "build_artifact"}], scanner=scan["scanner"], version=scan["version"]), surface
    hits = scan.get("hits", [])
    if hits:
        return result("FAIL", "LEAK_PATTERN_HIT", hits=hits, scanner=scan["scanner"], version=scan["version"]), surface
    return result("PASS", "SCAN_NO_HITS", scanner=scan["scanner"], version=scan["version"], note="No hits is not proof of no secrets."), surface


def check_surface(snapshot: dict[str, Any], surface: dict[str, Any]) -> dict[str, Any]:
    if surface["surface_class"] == "unknown":
        return result("UNVERIFIED", "SURFACE_UNKNOWN")
    if surface["flags"]:
        eligible = snapshot.get("eligibility_receipt")
        declared = eligible.get("data", {}).get("surface_class") if isinstance(eligible, dict) else None
        if declared != surface["surface_class"]:
            return result("UNVERIFIED", "SURFACE_CLASS_UNBOUND", **surface)
    return result("PASS", "SURFACE_FLAGS_RECORDED", **surface)


def check_issues(snapshot: dict[str, Any]) -> dict[str, Any]:
    reports = [snapshot.get("tester_report"), snapshot.get("builder_report")]
    if any(not report or report.get("error") for report in reports):
        return result("UNVERIFIED", "ISSUE_REPORT_MISSING")
    if any(report.get("H") != snapshot.get("H") for report in reports):
        return result("UNVERIFIED", "ISSUE_HEAD_UNBOUND")
    issues = [issue for report in reports for issue in report.get("issues", [])]
    blockers = [issue for issue in issues if issue.get("class") == "BLOCKER" and not issue.get("disposition_ref")]
    risks = [issue for issue in issues if issue.get("class") == "RISK" and not issue.get("disposition_ref")]
    if blockers:
        return result("FAIL", "BLOCKER_UNDISPOSED", blocker_count=len(blockers))
    if risks:
        return result("UNVERIFIED", "RISK_UNDISPOSED", risk_count=len(risks))
    return result("PASS", "ISSUES_DISPOSED", issue_count=len(issues), dispositions=[i["disposition_ref"] for i in issues])


def check_queue(snapshot: dict[str, Any]) -> dict[str, Any]:
    task = snapshot.get("task_record")
    events = snapshot.get("job_events")
    if not isinstance(task, dict) or not isinstance(events, list):
        return result("UNVERIFIED", "QUEUE_LOOKUP_FAILED")
    if task.get("id") != snapshot.get("task") or task.get("state") not in {"in_progress", "verifying", "join"}:
        return result("UNVERIFIED", "TASK_STATE_MISMATCH")
    if task.get("refs", {}).get("job_id") != snapshot.get("job"):
        return result("UNVERIFIED", "TASK_JOB_MISMATCH")
    claims = [e for e in events if e.get("kind") in ("job.claim", "job.reclaim")]
    joins = [e for e in events if e.get("kind") == "job.joined"]
    if not claims or not joins:
        return result("UNVERIFIED", "JOB_NOT_JOINED")
    claim = claims[-1].get("payload", claims[-1])
    join = joins[-1].get("payload", joins[-1])
    if claim.get("parent_lane") != task.get("lane") or claim.get("role") != "builder" or (task.get("claimed_by") and task["claimed_by"] != claim.get("parent_lane")):
        return result("UNVERIFIED", "OWNER_MISMATCH")
    if join.get("pr") != snapshot.get("pr_url") or join.get("head") != snapshot.get("H") or join.get("report_path") != snapshot.get("builder_report", {}).get("ref", {}).get("path"):
        return result("UNVERIFIED", "JOIN_BINDING_MISMATCH")
    return result("PASS", "QUEUE_JOIN_CONSISTENT", owner=claim.get("owner_lane"), parent=claim.get("parent_lane"))


def check_runtime(snapshot: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(snapshot.get("files"), list):
        return result("UNVERIFIED", "RUNTIME_DIFF_UNKNOWN")
    paths = [f.get("filename", "") for f in snapshot["files"]]
    repo = snapshot["repo"]
    entries = policy.get("runtime", {}).get(repo, [])
    matched = [entry for entry in entries if any(fnmatch.fnmatch(path, glob) for path in paths for glob in entry.get("code_globs", []) + entry.get("dependency_globs", []))]
    if len(matched) > 1:
        return result("UNVERIFIED", "RUNTIME_TARGET_UNKNOWN")
    if not matched:
        relevant = [p for p in paths if p.endswith((".py", ".service", ".service.example", "Dockerfile", "pyproject.toml", "uv.lock")) or fnmatch.fnmatch(p, "requirements*.txt") or p.startswith(("runners/", "deploy/", "scripts/"))]
        if relevant:
            return result("UNVERIFIED", "RUNTIME_TARGET_UNKNOWN")
        return result("N/A", "RUNTIME_SURFACE_ABSENT", policy_ref="runtime")
    entry = matched[0]
    receipt = snapshot.get("runtime_receipt")
    if not receipt or receipt.get("error"):
        return result("UNVERIFIED", "RUNTIME_RECEIPT_MISSING", service=entry["service"])
    data = receipt.get("data", {})
    required = {"kind": "host-runtime", "repo": repo, "PR": snapshot["PR"], "H": snapshot["H"], "target": entry["target"], "service": entry["service"], "interpreter": entry["interpreter"]}
    if any(data.get(key) != value for key, value in required.items()):
        return result("UNVERIFIED", "RUNTIME_RECEIPT_MISMATCH")
    if data.get("issuer") in (None, "", snapshot.get("issuer")):
        return result("UNVERIFIED", "RUNTIME_NOT_INDEPENDENT")
    try:
        observed = parse_time(data["observed_at"])
        now = parse_time(snapshot["time"])
    except (ValueError, KeyError, TypeError):
        return result("UNVERIFIED", "RUNTIME_TIME_INVALID")
    if observed > now or now - observed > timedelta(hours=24):
        return result("UNVERIFIED", "RUNTIME_OBSERVATION_STALE")
    if not str(data.get("version", "")).startswith(entry["version_prefix"]) or not os.path.isabs(str(data.get("interpreter", ""))):
        return result("UNVERIFIED", "RUNTIME_INTERPRETER_MISMATCH")
    if entry["interpreter"] not in str(data.get("exec_start", "")) or not all(data.get(key) for key in ("os", "arch", "lock_ref", "dependencies_ref", "proof_ref")):
        return result("UNVERIFIED", "RUNTIME_OBSERVATION_INCOMPLETE")
    return result("PASS", "RUNTIME_HOST_OBSERVED", receipt=receipt["ref"], target=entry["target"], service=entry["service"])


def check_hash(snapshot: dict[str, Any]) -> dict[str, Any]:
    texts = [snapshot.get("pr_body", ""), snapshot.get("deploy_note", "")]
    cited = {sha.lower() for content in texts for sha in ARTIFACT_SHA.findall(content)}
    if not cited:
        return result("N/A", "ARTIFACT_HASH_NOT_CITED", policy_ref="artifact_hash", note="Post-merge binary hashes are not verified by this tool.")
    receipts = snapshot.get("hash_receipts")
    if receipts is None:
        receipts = [snapshot["hash_receipt"]] if snapshot.get("hash_receipt") else []
    if not receipts or any(not receipt or receipt.get("error") for receipt in receipts):
        return result("UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING", cited_count=len(cited))
    bound: set[str] = set()
    for receipt in receipts:
        data = receipt.get("data", {})
        if data.get("kind") != "artifact-hash" or data.get("H") != snapshot["H"] or data.get("repo") != snapshot["repo"] or data.get("PR") != snapshot["PR"] or data.get("issuer") in (None, "", snapshot.get("issuer")):
            return result("UNVERIFIED", "ARTIFACT_HASH_UNBOUND")
        artifacts = data.get("artifacts") or [{"sha256": data.get("sha256"), "artifact_ref": data.get("artifact_ref")}]
        if not isinstance(artifacts, list) or not artifacts:
            return result("UNVERIFIED", "ARTIFACT_HASH_UNBOUND")
        for artifact in artifacts:
            sha = artifact.get("sha256", "").lower() if isinstance(artifact, dict) else ""
            if not SHA256.fullmatch(sha) or sha not in cited or not artifact.get("artifact_ref"):
                return result("UNVERIFIED", "ARTIFACT_HASH_UNBOUND")
            bound.add(sha)
    if bound != cited:
        return result("UNVERIFIED", "ARTIFACT_HASH_RECEIPT_MISSING", cited_count=len(cited), bound_count=len(bound))
    return result("PASS", "ARTIFACT_HASH_INDEPENDENT", receipts=[receipt["ref"] for receipt in receipts], note="Post-merge binary hashes are not verified by this tool.")


def evaluate(snapshot: dict[str, Any], policy: dict[str, Any]) -> dict[str, dict[str, Any]]:
    ci = evaluate_required_ci(policy, snapshot["repo"], snapshot.get("H"), snapshot.get("B"),
                              snapshot.get("ci_runs", []), snapshot.get("ci_jobs", {}), snapshot.get("protection_contexts"))
    diff, surface = check_diff(snapshot, policy)
    return {
        "G1": check_reports(snapshot),
        "G2": check_head(snapshot),
        "G3": ci,
        "G4": check_base(snapshot, ci),
        "G5": diff,
        "G6": check_surface(snapshot, surface),
        "G7": check_issues(snapshot),
        "G8": check_queue(snapshot),
        "G9": check_runtime(snapshot, policy),
        "G10": check_hash(snapshot),
    }


def read_json_receipt(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    try:
        source = Path(path).expanduser().resolve()
        raw = source.read_bytes()
        ref = {"path": str(source), "sha256": sha256_bytes(raw)}
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("object required")
        return {"ref": ref, "data": data}
    except (OSError, UnicodeError, ValueError):
        return {"error": "RECEIPT_UNREADABLE"}


def scan_patches(files: list[dict[str, Any]], B: str, H: str) -> dict[str, Any]:
    """Scan all added lines with gitleaks plus local location-only classes."""
    lines: list[str] = []
    locations: list[str] = []
    hits: list[dict[str, str]] = []
    for file in files:
        patch = file.get("patch")
        path = file.get("filename")
        additions, deletions = file.get("additions"), file.get("deletions")
        if not isinstance(patch, str) or not isinstance(path, str) or not isinstance(additions, int) or not isinstance(deletions, int):
            return {"complete": False, "H": H, "B": B, "scanner": "gitleaks", "version": None, "exit_code": None, "hits": []}
        new_line = 0
        patch_additions = 0
        patch_deletions = 0
        for line in patch.splitlines():
            if line.startswith("@@"):
                m = re.search(r"\+(\d+)", line)
                if not m:
                    return {"complete": False, "H": H, "B": B, "scanner": "gitleaks", "version": None, "exit_code": None, "hits": []}
                new_line = int(m.group(1))
            elif line.startswith("+") and not line.startswith("+++"):
                added = line[1:]
                location = f"{path}:{new_line}"
                lines.append(added)
                locations.append(location)
                patch_additions += 1
                for name, pattern in SENSITIVE.items():
                    if pattern.search(added):
                        hits.append({"location": location, "class": name})
                new_line += 1
            elif line.startswith("-") and not line.startswith("---"):
                patch_deletions += 1
            elif not line.startswith("-") and not line.startswith("\\"):
                new_line += 1
        if (patch_additions, patch_deletions) != (additions, deletions):
            return {"complete": False, "H": H, "B": B, "scanner": "gitleaks", "version": None, "exit_code": None, "hits": []}
    try:
        version = subprocess.run(["gitleaks", "version"], capture_output=True, text=True, timeout=10, check=False)
        if version.returncode:
            raise RuntimeError("scanner version")
        scanned = subprocess.run(["gitleaks", "stdin", "--no-banner", "--log-level", "error", "--redact", "--report-format", "json", "--report-path", "-"],
                                 input="\n".join(lines) + "\n", capture_output=True, text=True, timeout=60, check=False)
        if scanned.returncode not in (0, 1):
            raise RuntimeError("scanner failed")
        findings = json.loads(scanned.stdout)
        if not isinstance(findings, list):
            raise RuntimeError("scanner output")
        for finding in findings:
            index = int(finding.get("StartLine", 0)) - 1
            location = locations[index] if 0 <= index < len(locations) else "diff:unknown"
            hits.append({"location": location, "class": str(finding.get("RuleID") or "gitleaks")})
        if scanned.returncode == 1 and not findings:
            raise RuntimeError("scanner result mismatch")
        return {"complete": True, "H": H, "B": B, "scanner": "gitleaks+merge-precheck-patterns", "version": version.stdout.strip(),
                "exit_code": scanned.returncode, "hits": sorted(hits, key=lambda item: (item["location"], item["class"]))}
    except (OSError, subprocess.TimeoutExpired, RuntimeError, ValueError, json.JSONDecodeError):
        return {"complete": False, "H": H, "B": B, "scanner": "gitleaks", "version": None, "exit_code": None, "hits": []}


def gather_live(args: argparse.Namespace, policy: dict[str, Any]) -> dict[str, Any]:
    repo, number = args.repo, args.pr
    snapshot: dict[str, Any] = {"repo": repo, "PR": number, "task": args.task, "job": args.job,
        "issuer": args.issuer, "time": iso_now(), "expected_H": args.head, "deploy_note": "",
        "tester_report": parse_report(args.tester_report, args.tester_report_sha256),
        "builder_report": parse_report(args.builder_report, args.builder_report_sha256),
        "eligibility_receipt": read_json_receipt(args.eligibility_receipt),
        "runtime_receipt": read_json_receipt(args.runtime_receipt),
        "hash_receipts": [read_json_receipt(path) for path in (args.hash_receipt or [])],
        "ci_runs": [], "ci_jobs": {}, "files": None, "scan": None, "job_events": None, "tester_events": None,
        "task_record": None, "head_to_base": None, "M": None, "merge_parents": []}
    try:
        pr = gh_api(f"repos/{repo}/pulls/{number}")
        H = pr["head"]["sha"]
        branch = pr["base"]["ref"]
        head_repo = pr["head"]["repo"]["full_name"]
        head_branch = pr["head"]["ref"]
        snapshot.update({"H": H, "pr_url": pr["html_url"], "pr_body": pr.get("body") or "",
                         "trial_merge_commit": pr.get("merge_commit_sha"), "base_branch": branch})
        base_ref = gh_api(f"repos/{repo}/git/ref/heads/{quote(branch, safe='')}")
        head_ref = gh_api(f"repos/{head_repo}/git/ref/heads/{quote(head_branch, safe='')}")
        B = base_ref["object"]["sha"]
        snapshot.update({"B": B, "base_ref_sha": B, "head_ref_sha": head_ref["object"]["sha"]})
        snapshot["head_to_base"] = gh_api(f"repos/{repo}/compare/{H}...{B}")
        comparison = gh_api(f"repos/{repo}/compare/{B}...{H}")
        files = comparison.get("files")
        if isinstance(files, list) and len(files) < 300:
            snapshot["files"] = files
            snapshot["scan"] = scan_patches(files, B, H)
        if snapshot["trial_merge_commit"]:
            try:
                merge = gh_api(f"repos/{repo}/git/commits/{snapshot['trial_merge_commit']}")
                snapshot["merge_parents"] = [parent["sha"] for parent in merge.get("parents", [])]
                snapshot["M"] = merge["tree"]["sha"]
            except (RuntimeError, KeyError, TypeError):
                pass
        if args.deploy_note:
            snapshot["deploy_note"] = Path(args.deploy_note).expanduser().read_text(encoding="utf-8")
    except (RuntimeError, KeyError, TypeError, OSError, UnicodeError):
        # Independent checks remain UNVERIFIED when one GitHub lookup fails.
        pass
    H = snapshot.get("H")
    if isinstance(H, str) and SHA.fullmatch(H):
        try:
            runs = gh_pages(f"repos/{repo}/actions/runs?head_sha={H}&event=pull_request", key="workflow_runs")
            snapshot["ci_runs"] = runs
            for run in runs:
                run_id = run.get("id")
                if isinstance(run_id, int):
                    snapshot["ci_jobs"][run_id] = gh_pages(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=all", key="jobs")
        except (RuntimeError, KeyError, TypeError):
            snapshot["ci_runs"] = []
            snapshot["ci_jobs"] = {}
    if repo == "mgh3326/auto_trader" and snapshot.get("base_branch"):
        try:
            protection = gh_api(f"repos/{repo}/branches/{quote(snapshot['base_branch'], safe='')}/protection/required_status_checks")
            snapshot["protection_contexts"] = protection["contexts"]
        except (RuntimeError, KeyError, TypeError):
            snapshot["protection_contexts"] = None
    try:
        snapshot["task_record"] = run_json(["handoffkeep", "tasks", "show", str(args.task)])
    except RuntimeError:
        pass
    if args.job and re.fullmatch(r"[A-Za-z0-9_-]+", args.job):
        event_dir = Path.home() / "work/herdr-inbox/jobs" / args.job / "events"
        try:
            snapshot["job_events"] = [json.loads(path.read_text(encoding="utf-8")) for path in sorted(event_dir.glob("*.json"))]
            claims = [event for event in snapshot["job_events"] if event.get("kind") in ("job.claim", "job.reclaim")]
            snapshot["tier"] = claims[-1].get("payload", {}).get("t_level") if claims else None
        except (OSError, UnicodeError, ValueError):
            pass
    tester_job = snapshot["tester_report"].get("metadata", {}).get("TESTER_JOB")
    if isinstance(tester_job, str) and re.fullmatch(r"[A-Za-z0-9_-]+", tester_job):
        event_dir = Path.home() / "work/herdr-inbox/jobs" / tester_job / "events"
        try:
            snapshot["tester_events"] = [json.loads(path.read_text(encoding="utf-8")) for path in sorted(event_dir.glob("*.json"))]
        except (OSError, UnicodeError, ValueError):
            pass
    return snapshot


def passing_merge_receipt(receipt: dict[str, Any]) -> bool:
    checks = receipt.get("checks")
    return isinstance(checks, dict) and all(
        isinstance(checks.get(f"G{number}"), dict) and checks[f"G{number}"].get("status") in ("PASS", "N/A")
        for number in range(1, 11)
    )


def audit(receipt_dir: Path, policy: dict[str, Any], since: str) -> dict[str, Any]:
    """Anti-join actual merged PRs and wrk spawns against pre-action receipts."""
    try:
        start = parse_time(since)
    except (ValueError, TypeError):
        return {"status": "UNVERIFIED", "reason_code": "AUDIT_TIME_INVALID"}
    receipts = []
    try:
        for path in receipt_dir.expanduser().glob("*.json"):
            item = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(item, dict):
                receipts.append(item)
    except (OSError, ValueError):
        return {"status": "UNVERIFIED", "reason_code": "AUDIT_RECEIPT_LOOKUP_FAILED"}
    actions: list[dict[str, Any]] = []
    try:
        for repo in policy["ci"]:
            since_date = start.date().isoformat()
            search = gh_api(f"search/issues?q={quote(f'repo:{repo} is:pr is:merged merged:>={since_date}', safe='')}&per_page=100&page=1")
            if not isinstance(search.get("total_count"), int) or search["total_count"] > 1000:
                raise RuntimeError("AUDIT_LEDGER_TRUNCATED")
            issues = gh_pages(f"search/issues?q={quote(f'repo:{repo} is:pr is:merged merged:>={since_date}', safe='')}", key="items", limit=10)
            if len(issues) != search["total_count"]:
                raise RuntimeError("AUDIT_LEDGER_TRUNCATED")
            for issue in issues:
                pr = gh_api(f"repos/{repo}/pulls/{issue['number']}")
                if not pr.get("merged_at") or parse_time(pr["merged_at"]) < start:
                    continue
                actions.append({"kind": "merge", "repo": repo, "PR": pr["number"], "H": pr["head"]["sha"], "at": pr["merged_at"]})
        jobs_root = Path.home() / "work/herdr-inbox/jobs"
        for event in jobs_root.glob("*/events/*-job.spawned.json"):
            row = json.loads(event.read_text(encoding="utf-8"))
            if parse_time(row["created_at"]) >= start:
                actions.append({"kind": "spawn", "job": row.get("job_id"), "at": row["created_at"]})
    except (RuntimeError, KeyError, OSError, ValueError):
        return {"status": "UNVERIFIED", "reason_code": "AUDIT_LEDGER_LOOKUP_FAILED"}
    counts = {"actions": len(actions), "no_receipt": 0, "receipt_after_action": 0, "receipt_not_pass": 0, "reused_receipt": 0}
    uses: dict[str, int] = {}
    for action in actions:
        matches = [r for r in receipts if r.get("kind") == action["kind"] and (
            (action["kind"] == "merge" and r.get("repo") == action["repo"] and r.get("PR") == action["PR"] and r.get("H") == action["H"])
            or (action["kind"] == "spawn" and r.get("job") == action["job"]))]
        if not matches:
            counts["no_receipt"] += 1
        else:
            try:
                earlier = [r for r in matches if parse_time(r["time"]) <= parse_time(action["at"])]
            except (KeyError, ValueError, TypeError):
                return {"status": "UNVERIFIED", "reason_code": "AUDIT_RECEIPT_TIME_INVALID"}
            if not earlier:
                counts["receipt_after_action"] += 1
            elif action["kind"] == "merge" and not any(passing_merge_receipt(r) for r in earlier):
                counts["receipt_not_pass"] += 1
        for receipt in matches:
            uses[receipt["action_id"]] = uses.get(receipt["action_id"], 0) + 1
    ids: dict[str, int] = {}
    for receipt in receipts:
        action_id = receipt.get("action_id")
        if isinstance(action_id, str):
            ids[action_id] = ids.get(action_id, 0) + 1
    counts["reused_receipt"] = len({action_id for action_id, count in uses.items() if count > 1} | {action_id for action_id, count in ids.items() if count > 1})
    bypass = any(counts[key] for key in ("no_receipt", "receipt_after_action", "receipt_not_pass", "reused_receipt"))
    return {"status": "FAIL" if bypass else "PASS", "reason_code": "AUDIT_BYPASS_DETECTED" if bypass else "AUDIT_COMPLETE", "since": since, **counts}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Shadow merge precheck and receipt audit")
    parser.add_argument("repo", help="owner/repo, or audit")
    parser.add_argument("pr", type=int, nargs="?")
    parser.add_argument("--task", type=int)
    parser.add_argument("--job")
    parser.add_argument("--head")
    parser.add_argument("--tester-report")
    parser.add_argument("--tester-report-sha256")
    parser.add_argument("--builder-report")
    parser.add_argument("--builder-report-sha256")
    parser.add_argument("--eligibility-receipt")
    parser.add_argument("--runtime-receipt")
    parser.add_argument("--hash-receipt", action="append")
    parser.add_argument("--deploy-note")
    parser.add_argument("--issuer", default="director-1")
    parser.add_argument("--receipt-dir", default=str(Path.home() / "work/herdr-inbox/receipts"))
    parser.add_argument("--policy", default=str(POLICY_PATH))
    parser.add_argument("--since")
    args = parser.parse_args(argv)
    try:
        policy, policy_ref = load_policy(args.policy)
    except PolicyError as exc:
        if args.repo == "audit":
            print(json.dumps({"status": "UNVERIFIED", "reason_code": exc.code}, sort_keys=True))
            return 2
        try:
            ref = file_ref(args.policy)
        except OSError:
            ref = {"path": str(Path(args.policy).expanduser().resolve()), "sha256": None}
        checks = {f"G{number}": result("UNVERIFIED", exc.code) for number in range(1, 11)}
        receipt = {"action_id": uuid.uuid4().hex, "kind": "merge", "task": args.task, "job": args.job,
                   "repo": args.repo, "PR": args.pr, "H": None, "B": None, "M": None,
                   "policy": {**ref, "revision": None}, "tool_version": VERSION,
                   "issuer": args.issuer, "time": iso_now(), "evidence": {}, "checks": checks}
        try:
            path = write_receipt(receipt, args.receipt_dir)
        except (OSError, ValueError):
            print("merge-precheck UNVERIFIED RECEIPT_WRITE_FAILED")
            return 2
        print(f"merge-precheck UNVERIFIED {exc.code} receipt={path}")
        return 1
    if args.repo == "audit":
        finding = audit(Path(args.receipt_dir), policy, args.since or policy["effective_at"])
        print(json.dumps(finding, sort_keys=True))
        return 0 if finding["status"] == "PASS" else 2
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) or not args.pr or not args.task:
        parser.error("repo, pr and --task are required")
    snapshot = gather_live(args, policy)
    checks = evaluate(snapshot, policy)
    receipt = {"action_id": uuid.uuid4().hex, "kind": "merge", "task": args.task, "job": args.job,
        "repo": args.repo, "PR": args.pr, "H": snapshot.get("H"), "B": snapshot.get("B"), "M": snapshot.get("M"),
        "trial_merge_commit": snapshot.get("trial_merge_commit"),
        "policy": policy_ref, "tool_version": VERSION, "issuer": args.issuer, "time": snapshot["time"],
        "evidence": {"tester_report": snapshot["tester_report"].get("ref"),
                     "builder_report": snapshot["builder_report"].get("ref"),
                     "eligibility_receipt": snapshot["eligibility_receipt"].get("ref") if snapshot["eligibility_receipt"] else None,
                     "ci_jobs": checks["G3"].get("jobs", []),
                     "runtime_receipt": snapshot["runtime_receipt"].get("ref") if snapshot["runtime_receipt"] else None,
                     "hash_receipts": [receipt.get("ref") for receipt in snapshot["hash_receipts"]]},
        "checks": checks,
        "merge_command": f"gh pr merge {args.pr} -R {args.repo} --merge --match-head-commit {snapshot['H']}" if snapshot.get("H") else None,
        "merge_path_limit": "--match-head-commit pins H; it does not atomically pin B. Re-read remote B and H immediately before merge. No post-merge binary hash is verified."}
    try:
        path = write_receipt(receipt, args.receipt_dir)
    except (OSError, ValueError):
        print("merge-precheck UNVERIFIED RECEIPT_WRITE_FAILED")
        return 2
    overall = "PASS" if all(c["status"] in ("PASS", "N/A") for c in checks.values()) else ("FAIL" if any(c["status"] == "FAIL" for c in checks.values()) else "UNVERIFIED")
    print(f"merge-precheck {overall} {args.repo}#{args.pr} H={snapshot.get('H') or 'unknown'} receipt={path}")
    return 0 if overall == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
