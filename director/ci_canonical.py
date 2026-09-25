"""Canonical required-CI evaluator shared with task #723.

Entry point: evaluate_required_ci(policy, repo, H, B, runs, jobs_by_run,
protection_contexts=None). All inputs are GitHub API JSON snapshots. The caller
must independently collect the current PR head and base. This module never
treats absent branch protection, a skipped job, or a green third-party check
as a successful repository CI job.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any


EXCLUDED = ("CodeRabbit", "CommitCheck", "qlty", "AccessLint", "WIP", "GitGuardian", "Codecov")
COMMAND_STEP_MARKERS = {"go test", "go test -race", "go build", "npm test"}


def _result(status: str, code: str, **extra: Any) -> dict[str, Any]:
    return {"status": status, "reason_code": code, **extra}


def _run_time(run: dict[str, Any]) -> datetime:
    raw = run.get("created_at")
    if not isinstance(raw, str):
        raise ValueError("run timestamp missing")
    instant = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    if instant.tzinfo is None:
        raise ValueError("run timestamp has no timezone")
    return instant


def _step_matches(marker: str, name: str) -> bool:
    expected = marker.casefold().strip()
    actual = name.casefold().strip()
    if actual == expected:
        return True
    if expected not in COMMAND_STEP_MARKERS:
        return False
    return actual.startswith(expected + " ") or actual == "run " + expected or actual.startswith("run " + expected + " ")


def evaluate_required_ci(
    policy: dict[str, Any], repo: str, H: str, B: str,
    runs: list[dict[str, Any]], jobs_by_run: dict[int, list[dict[str, Any]]],
    protection_contexts: list[str] | None = None,
) -> dict[str, Any]:
    """Return PASS/FAIL/UNVERIFIED and exact run/job evidence for every R job.

    A whole workflow attempt is chosen. Rerunning one failed job cannot hide a
    later red attempt. The tested base comes from the checkout merge commit
    recorded in an immutable job log, never the mutable pull_requests array.
    """
    workflows = policy.get("ci", {}).get(repo)
    if not isinstance(workflows, dict) or not workflows:
        return _result("UNVERIFIED", "CI_POLICY_UNKNOWN", jobs=[])
    required = [(workflow, name) for workflow, names in workflows.items() for name in names]
    if not required or any(not name or name.startswith(EXCLUDED) for _, name in required):
        return _result("UNVERIFIED", "CI_REQUIRED_SET_INVALID", jobs=[])
    execution_by_repo = policy.get("ci_execution_steps")
    execution = execution_by_repo.get(repo) if isinstance(execution_by_repo, dict) else None
    if not isinstance(execution, dict) or set(execution) != {name for _, name in required} or any(
        not isinstance(markers, list) or not markers or any(not isinstance(marker, str) or not marker for marker in markers)
        for markers in execution.values()
    ):
        return _result("UNVERIFIED", "CI_EXECUTION_POLICY_UNKNOWN", jobs=[])
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
        try:
            order = {id(run): _run_time(run) for run in candidates}
        except (ValueError, TypeError):
            return _result("UNVERIFIED", "CI_RUN_TIME_INVALID", jobs=observations)
        if workflow == "branch_protection":
            # The six protection contexts may live in several workflows. Jobs
            # are resolved by their actual workflow run, never status names alone.
            latest_by_path: dict[str, dict[str, Any]] = {}
            for run in candidates:
                path = run.get("path")
                old = latest_by_path.get(path)
                if old is None or (order[id(run)], int(run.get("run_attempt") or 0)) > (order[id(old)], int(old.get("run_attempt") or 0)):
                    latest_by_path[path] = run
            if any(sum((order[id(candidate)], int(candidate.get("run_attempt") or 0)) ==
                       (order[id(chosen)], int(chosen.get("run_attempt") or 0))
                       for candidate in candidates if candidate.get("path") == path) > 1
                   for path, chosen in latest_by_path.items()):
                return _result("UNVERIFIED", "CI_RUN_AMBIGUOUS", jobs=observations)
            selected = list(latest_by_path.values())
        else:
            selected = sorted(candidates, key=lambda r: (order[id(r)], int(r.get("run_attempt") or 0)))
            if len(selected) > 1 and (order[id(selected[-1])], int(selected[-1].get("run_attempt") or 0)) == (
                order[id(selected[-2])], int(selected[-2].get("run_attempt") or 0)):
                return _result("UNVERIFIED", "CI_RUN_AMBIGUOUS", jobs=observations)
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
            if len(possible) != 1:
                conclusions = {job.get("conclusion") for _, job in possible}
                code = "CI_SKIPPED" if "skipped" in conclusions else ("CI_FAILED" if any(value not in ("success", None) for value in conclusions) else "CI_JOB_AMBIGUOUS")
                problems.append((name, code))
                continue
            run, job = possible[0]
            item = {"workflow": run.get("path"), "name": name, "run_id": run.get("id"),
                    "attempt": run.get("run_attempt"), "job_id": job.get("id"),
                    "head_sha": run.get("head_sha"), "base_sha": job.get("tested_base_sha"),
                    "tested_merge_sha": job.get("tested_merge_sha"), "merge_tree": job.get("tested_merge_tree"),
                    "base_source": "checkout_job_log_and_merge_parents" if job.get("tested_base_sha") else None,
                    "run_conclusion": run.get("conclusion"), "job_conclusion": job.get("conclusion"),
                    "execution_steps": []}
            observations.append(item)
            if run.get("head_sha") != H or job.get("head_sha") != H or job.get("run_id") != run.get("id"):
                problems.append((name, "CI_HEAD_MISMATCH"))
            elif run.get("status") != "completed" or job.get("status") != "completed":
                problems.append((name, "CI_PENDING"))
            elif job.get("conclusion") == "skipped":
                problems.append((name, "CI_SKIPPED"))
            elif job.get("conclusion") != "success":
                problems.append((name, "CI_FAILED"))
            else:
                steps = job.get("steps")
                if not isinstance(steps, list):
                    problems.append((name, "CI_REQUIRED_STEP_MISSING"))
                    continue
                step_problem = None
                for marker in execution[name]:
                    matched = [step for step in steps if isinstance(step, dict) and isinstance(step.get("name"), str)
                               and _step_matches(marker, step["name"])]
                    if len(matched) != 1:
                        step_problem = "CI_REQUIRED_STEP_MISSING" if not matched else "CI_STEP_AMBIGUOUS"
                        break
                    step = matched[0]
                    item["execution_steps"].append({"name": step["name"], "status": step.get("status"), "conclusion": step.get("conclusion")})
                    if step.get("status") != "completed":
                        step_problem = "CI_PENDING"
                        break
                    if step.get("conclusion") == "skipped":
                        step_problem = "CI_SKIPPED"
                        break
                    if step.get("conclusion") != "success":
                        step_problem = "CI_FAILED"
                        break
                if step_problem:
                    problems.append((name, step_problem))
                elif not item["base_sha"] or not item["tested_merge_sha"] or not item["merge_tree"]:
                    problems.append((name, "CI_BASE_UNBOUND"))
                elif item["base_sha"] != B:
                    problems.append((name, "CI_BASE_MOVED"))
    if problems:
        failures = {"CI_FAILED", "CI_SKIPPED", "CI_HEAD_MISMATCH"}
        name, code = next(((name, code) for name, code in problems if code in failures), problems[0])
        status = "FAIL" if code in failures else "UNVERIFIED"
        return _result(status, code, job=name, problems=[{"job": n, "reason_code": c} for n, c in problems], jobs=observations)
    return _result("PASS", "CI_ALL_REQUIRED_SUCCEEDED", jobs=observations)
