"""Shared, read-only policy and receipt plumbing for shadow gate commands.

The policy file is the sole editable policy snapshot. A source revision mismatch
invalidates it; callers must never silently substitute a launcher or a newer rule.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from datetime import datetime, timezone
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_POLICY = ROOT / "director" / "gate_policy.json"
DEFAULT_RECEIPTS = Path.home() / "work/herdr-inbox/receipts"
GRADES = ("C", "B", "A", "A+", "S", "S+")
TOOL_VERSION = "tester-eligible/1.0"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_time(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone required")
    return parsed.astimezone(timezone.utc)


def result(status: str, reason: str, ref: str, **details: object) -> dict:
    if status not in {"PASS", "FAIL", "UNVERIFIED", "N/A"}:
        raise ValueError("invalid status")
    return {"status": status, "reason_code": reason, "policy_ref": ref, **details}


def overall(checks: dict) -> str:
    statuses = {entry["status"] for entry in checks.values()}
    if "FAIL" in statuses:
        return "FAIL"
    if "UNVERIFIED" in statuses:
        return "UNVERIFIED"
    return "PASS"


def load_policy(path: Path = DEFAULT_POLICY, *, now: datetime | None = None,
                root: Path = ROOT) -> tuple[dict | None, dict]:
    try:
        raw = path.read_bytes()
        policy = json.loads(raw)
    except (OSError, ValueError):
        return None, result("UNVERIFIED", "POLICY_UNREADABLE", "decision:3231")
    try:
        if policy["schema"] != 1 or not policy["revision"] or not policy["sources"]:
            raise ValueError("schema")
        instant = now or utc_now()
        if not parse_time(policy["effective_at"]) <= instant < parse_time(policy["expires_at"]):
            return policy, result("UNVERIFIED", "POLICY_STALE", "decision:3231")
        expected_ids = {
            "decision/2026-09-25/director-throughput-adopted": 3231,
            "decision/2026-09-20/provider-family-and-ds41-grade": 2227,
        }
        for key, doc_id in expected_ids.items():
            if policy["sources"].get(key, {}).get("id") != doc_id:
                return policy, result("UNVERIFIED", "POLICY_CONFLICT", "decision:3231")
        for rel, expected in policy["local_sources"].items():
            source = root / rel
            if not source.is_file() or sha256_file(source) != expected:
                return policy, result("UNVERIFIED", "POLICY_STALE", rel)
        return policy, result("PASS", "POLICY_CURRENT", "decision:3231")
    except (KeyError, TypeError, ValueError):
        return policy, result("UNVERIFIED", "POLICY_CONFLICT", "decision:3231")


def run_git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(repo), *args], text=True,
                          capture_output=True, check=False)


def _wrk_clause(wrk_text: str, alias: str) -> str | None:
    block = wrk_text.split("resolve_profile() {", 1)[-1]
    block = block.split('  case "$MODEL" in', 1)[-1]
    block = block.split('    *) die "unknown model profile', 1)[0]
    lines = block.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^    ([a-z0-9_|-]+)\)\s*(.*)$", line)
        if match and alias in match.group(1).split("|"):
            clause = match.group(2)
            if ";;" in clause:
                return clause.split(";;", 1)[0]
            for following in lines[index + 1:]:
                clause += " " + following.strip()
                if ";;" in following:
                    return clause.split(";;", 1)[0]
    return None


def resolve_profile(alias: str, policy: dict, *, actual_model: str | None = None,
                    actual_effort: str | None = None, role: str = "tester",
                    root: Path = ROOT) -> tuple[dict | None, dict]:
    spec = policy.get("profiles", {}).get(alias)
    if not isinstance(spec, dict):
        return None, result("UNVERIFIED", "PROFILE_UNKNOWN", "bin/wrk:resolve_profile")
    try:
        clause = _wrk_clause((root / "bin/wrk").read_text(), alias)
        if clause is None:
            return None, result("UNVERIFIED", "PROFILE_UNKNOWN", "bin/wrk:resolve_profile")
        kind = re.search(r"PROFILE_KIND=([a-z]+)", clause)
        if not kind or kind.group(1) != spec["launcher"]:
            return None, result("UNVERIFIED", "POLICY_CONFLICT", "bin/wrk:resolve_profile")
        token = spec["launcher_model_token"]
        if token and token not in clause:
            return None, result("UNVERIFIED", "POLICY_CONFLICT", "bin/wrk:resolve_profile")
        default_match = re.search(r"DEFAULT_EFFORT=([a-z]+)", clause)
        default = default_match.group(1) if default_match else spec.get("default_effort", "")
        if default != spec.get("default_effort", ""):
            return None, result("UNVERIFIED", "POLICY_CONFLICT", "bin/wrk:resolve_profile")
        effort = actual_effort if actual_effort is not None else default
        if effort not in spec["grades"]:
            return None, result("UNVERIFIED", "PROFILE_EFFORT_UNKNOWN", "policy:profiles")
        if actual_model is not None and actual_model != spec["model"]:
            return None, result("UNVERIFIED", "ACTUAL_MODEL_MISMATCH", "decision:2227")
        if role not in spec["roles"]:
            status = "UNVERIFIED" if spec.get("role_status") == "unknown" else "FAIL"
            reason = "PROFILE_ROLE_UNKNOWN" if status == "UNVERIFIED" else "PROFILE_ROLE_DENIED"
            return None, result(status, reason, "policy:profiles")
        grade = spec["grades"][effort]
        resolved = {"alias": alias, "launcher": spec["launcher"], "family": spec["family"],
                    "model": spec["model"], "effort": effort, "grade": grade,
                    "roles": spec["roles"], "surfaces": spec["surfaces"]}
        if grade not in GRADES or spec["family"] == "unknown":
            return resolved, result("UNVERIFIED", "PROFILE_GRADE_UNKNOWN", "policy:profiles", **resolved)
        return resolved, result("PASS", "PROFILE_RESOLVED", "bin/wrk+policy:profiles")
    except (KeyError, TypeError, OSError):
        return None, result("UNVERIFIED", "POLICY_CONFLICT", "policy:profiles")


def write_receipt(receipt: dict, directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    name = f'{receipt["action_id"]}.json'
    target = directory / name
    payload = (json.dumps(receipt, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode()
    fd, temp_name = tempfile.mkstemp(prefix=".receipt-", dir=directory)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, target)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)
    return target


def new_action_id() -> str:
    return str(uuid4())
