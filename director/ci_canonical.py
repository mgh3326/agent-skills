"""Canonical required-CI evaluator shared with task #723.

Entry point: evaluate_required_ci(policy, repo, H, B, runs, jobs_by_run,
protection_contexts=None). All inputs are GitHub API JSON snapshots. The caller
must independently collect the current PR head and base. This module never
treats absent branch protection, a skipped job, or a green third-party check
as a successful repository CI job.
"""

from __future__ import annotations

from typing import Any


EXCLUDED = ("CodeRabbit", "CommitCheck", "qlty", "AccessLint", "WIP", "GitGuardian", "Codecov")


def _result(status: str, code: str, **extra: Any) -> dict[str, Any]:
    return {"status": status, "reason_code": code, **extra}


def _run_base(run: dict[str, Any]) -> str | None:
    bases = {entry.get("base", {}).get("sha") for entry in (run.get("pull_requests") or []) if isinstance(entry, dict)}
    bases.discard(None)
    return next(iter(bases)) if len(bases) == 1 else None


def evaluate_required_ci(
    policy: dict[str, Any], repo: str, H: str, B: str,
    runs: list[dict[str, Any]], jobs_by_run: dict[int, list[dict[str, Any]]],
    protection_contexts: list[str] | None = None,
) -> dict[str, Any]:
    """Return PASS/FAIL/UNVERIFIED and exact run/job evidence for every R job.

    A whole workflow attempt is chosen. Rerunning one failed job cannot hide a
    later red attempt. An event payload without its tested base SHA cannot
    establish the re-CI rule and is UNVERIFIED.
    """
    workflows = policy.get("ci", {}).get(repo)
    if not isinstance(workflows, dict) or not workflows:
        return _result("UNVERIFIED", "CI_POLICY_UNKNOWN", jobs=[])
    required = [(workflow, name) for workflow, names in workflows.items() for name in names]
    if not required or any(not name or name.startswith(EXCLUDED) for _, name in required):
        return _result("UNVERIFIED", "CI_REQUIRED_SET_INVALID", jobs=[])
    if "branch_protection" in workflows:
        if protection_contexts is None:
            return _result("UNVERIFIED", "CI_BRANCH_PROTECTION_MISSING", jobs=[])
        if set(protection_contexts) != set(workflows["branch_protection"]):
            return _result("UNVERIFIED", "CI_POLICY_CONFLICT", jobs=[])

    observations: list[dict[str, Any]] = []
    problems: list[tuple[str, str]] = []
    for workflow, expected in workflows.items():
        candidates = [run for run in runs if run.get("head_sha") == H and run.get("event") == "pull_request"
                      and (workflow == "branch_protection" or run.get("path") == workflow)]
        if workflow == "branch_protection":
            # The six protection contexts may live in several workflows. Jobs
            # are resolved by their actual workflow run, never status names alone.
            latest_by_path: dict[str, dict[str, Any]] = {}
            for run in candidates:
                path = run.get("path")
                old = latest_by_path.get(path)
                if old is None or (run.get("created_at", ""), int(run.get("run_attempt") or 0)) > (old.get("created_at", ""), int(old.get("run_attempt") or 0)):
                    latest_by_path[path] = run
            selected = list(latest_by_path.values())
        else:
            selected = sorted(candidates, key=lambda r: (r.get("created_at", ""), int(r.get("run_attempt") or 0)))
            selected = selected[-1:] if selected else []
        if not selected:
            problems.extend((name, "CI_RUN_MISSING") for name in expected)
            continue
        for name in expected:
            possible: list[tuple[dict[str, Any], dict[str, Any]]] = []
            for run in selected:
                run_id = run.get("id")
                for job in jobs_by_run.get(run_id, []):
                    if job.get("name") == name and job.get("run_attempt") == run.get("run_attempt"):
                        possible.append((run, job))
            if not possible:
                problems.append((name, "CI_JOB_MISSING"))
                continue
            run, job = max(possible, key=lambda item: (item[0].get("created_at", ""), int(item[0].get("run_attempt") or 0)))
            item = {"workflow": run.get("path"), "name": name, "run_id": run.get("id"),
                    "attempt": run.get("run_attempt"), "job_id": job.get("id"),
                    "head_sha": run.get("head_sha"), "base_sha": _run_base(run),
                    "run_conclusion": run.get("conclusion"), "job_conclusion": job.get("conclusion")}
            observations.append(item)
            if run.get("head_sha") != H or job.get("head_sha") != H or job.get("run_id") != run.get("id"):
                problems.append((name, "CI_HEAD_MISMATCH"))
            elif run.get("status") != "completed" or job.get("status") != "completed":
                problems.append((name, "CI_PENDING"))
            elif job.get("conclusion") == "skipped":
                problems.append((name, "CI_SKIPPED"))
            elif job.get("conclusion") != "success":
                problems.append((name, "CI_FAILED"))
            elif not any(step.get("status") == "completed" and step.get("conclusion") == "success"
                         and step.get("name") not in {"Set up job", "Complete job"} for step in (job.get("steps") or [])):
                problems.append((name, "CI_NOT_EXECUTED"))
            elif item["base_sha"] is None:
                problems.append((name, "CI_BASE_UNBOUND"))
            elif item["base_sha"] != B:
                problems.append((name, "CI_BASE_MOVED"))
    if problems:
        name, code = problems[0]
        status = "FAIL" if code in {"CI_FAILED", "CI_SKIPPED", "CI_HEAD_MISMATCH"} else "UNVERIFIED"
        return _result(status, code, job=name, problems=[{"job": n, "reason_code": c} for n, c in problems], jobs=observations)
    return _result("PASS", "CI_ALL_REQUIRED_SUCCEEDED", jobs=observations)
