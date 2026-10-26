#!/usr/bin/env python3
"""Prove the orphan-release assertions catch each named gc mutation."""

import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
ARBITER_SOURCE = ROOT / "bin" / "arbiter"
SCOPEFUEL = ROOT / "tests" / "fixtures" / "scopefuel"


def mutate(root: Path, name: str, old: str, new: str) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    source = ARBITER_SOURCE.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise AssertionError(f"{name}: mutant anchor occurs {source.count(old)} times")
    path = root / f"arbiter-{name}"
    path.write_text(source.replace(old, new, 1), encoding="utf-8")
    path.chmod(0o755)
    return path


def call(binary: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(binary), *args], env=env, text=True, capture_output=True, check=False
    )
    return result


def seed(root: Path, binary: Path, name: str, agent_status: str | None,
         path_lease: bool = False) -> tuple[dict[str, str], Path, str]:
    home = root / "home"
    xdg = root / "xdg"
    inbox = root / "inbox"
    tmp = root / "tmp"
    dirs = {
        "HOME": home,
        "XDG_CONFIG_HOME": root / "config",
        "XDG_CACHE_HOME": root / "cache",
        "XDG_DATA_HOME": xdg,
        "XDG_STATE_HOME": root / "state",
        "XDG_RUNTIME_DIR": root / "runtime",
        "CODEX_HOME": root / "codex",
        "ARBITER_INBOX_ROOT": inbox,
        "TMPDIR": tmp,
    }
    for directory in dirs.values():
        directory.mkdir(parents=True, exist_ok=True)
    dirs["XDG_RUNTIME_DIR"].chmod(0o700)
    env = os.environ.copy()
    env.update({key: str(value) for key, value in dirs.items()})
    env["WRK_TEST_MODE"] = "1"
    env["SCOPEFUEL_BIN"] = str(SCOPEFUEL)

    gate = root / "gate.out"
    gate_result = subprocess.run(
        [str(SCOPEFUEL), "gate", "-m", "codex-max"],
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    if gate_result.returncode != 0:
        raise AssertionError(f"fixture gate failed: {gate_result.stderr}")
    gate.write_text(gate_result.stdout, encoding="utf-8")

    agent_label = f"{name}-agent"
    for args in (
        ("claim", "--job", name, "--agent-label", agent_label,
         "--lane", "live", "--t", "T1"),
        ("lease", "--job", name, "--kind", "quota_pool", "--profile",
         "codex-max", "--gate-output", str(gate)),
    ):
        result = call(binary, env, *args)
        if result.returncode != 0:
            raise AssertionError(f"setup failed ({' '.join(args)}): {result.stderr}")
    if path_lease:
        result = call(binary, env, "lease", "--job", name, "--resource",
                      "path-left", "--kind", "path")
        if result.returncode != 0:
            raise AssertionError(f"path lease setup failed: {result.stderr}")

    agents = root / "agents.json"
    entries = [] if agent_status is None else [
        {"name": agent_label, "agent_status": agent_status}
    ]
    agents.write_text(json.dumps({"result": {"agents": entries}}), encoding="utf-8")
    return env, agents, name


def status(binary: Path, env: dict[str, str], job: str) -> dict:
    result = call(binary, env, "status", "--job", job, "--json")
    if result.returncode != 0:
        raise AssertionError(f"status failed for {job}: {result.stderr}")
    return json.loads(result.stdout)


def event_kinds(binary: Path, env: dict[str, str], job: str) -> list[str]:
    result = call(binary, env, "job-get", "--job", job, "--json")
    if result.returncode != 0:
        raise AssertionError(f"job-get failed for {job}: {result.stderr}")
    return json.loads(result.stdout)["recent_event_kinds"]


def exercise(root: Path, name: str, old: str, new: str, mode: str) -> None:
    binary = mutate(root, name, old, new)
    agent_status = "unknown" if mode == "unknown" else None
    env, agents, job = seed(
        root / "state-root", binary, f"orphan-{name}", agent_status,
        path_lease=(mode == "lease"),
    )
    gc = call(binary, env, "gc", "--herdr-agent-list", str(agents), "--json")
    current = status(binary, env, job)
    job_state = current["jobs"][0]["state"]
    kinds = event_kinds(binary, env, job)

    if mode == "missing-transition":
        if gc.returncode != 0 or job_state != "leased" or current["quota_pool_records"]:
            raise AssertionError(
                f"missing-transition mutant did not leave only the leased job: "
                f"rc={gc.returncode} state={current} stderr={gc.stderr}"
            )
        if "job.orphan_release" in kinds:
            raise AssertionError("missing-transition mutant wrote orphan_release")
        print("PASS mutant-gc-without-transition-goes-red")
    elif mode == "unknown":
        if gc.returncode != 0 or job_state != "released" or "job.orphan_release" not in kinds:
            raise AssertionError(
                f"unknown-transition mutant did not release the unknown owner: "
                f"rc={gc.returncode} state={current} events={kinds} stderr={gc.stderr}"
            )
        print("PASS mutant-gc-transition-on-unknown-goes-red")
    elif mode == "lease":
        leases = current["leases"]
        if gc.returncode != 0 or job_state != "released" or not leases:
            raise AssertionError(
                f"lease-left mutant did not release with its path lease remaining: "
                f"rc={gc.returncode} state={current} stderr={gc.stderr}"
            )
        if "job.orphan_release" not in kinds:
            raise AssertionError("lease-left mutant omitted its orphan_release event")
        print("PASS mutant-gc-transition-with-lease-left-goes-red")
    else:
        raise AssertionError(f"unknown mutant proof mode: {mode}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="arbiter-orphan-mutants-") as temp:
        root = Path(temp)
        exercise(
            root / "missing-transition",
            "gc-no-transition",
            "for job_id, (agent_label, statuses, reason) in sorted(orphan_candidates.items()):",
            "for job_id, (agent_label, statuses, reason) in []:",
            "missing-transition",
        )
        exercise(
            root / "unknown-transition",
            "gc-unknown-transition",
            '            if "unknown" in statuses:\n                unsafe_quota_pool.append(',
            '            if False and "unknown" in statuses:\n                unsafe_quota_pool.append(',
            "unknown",
        )
        exercise(
            root / "lease-left",
            "gc-lease-left",
            'eligible = bool(job and job[0] == "leased" and not leases and not quotas)  # hk1991-orphan-release',
            'eligible = bool(job and job[0] == "leased" and not quotas)  # hk1991-orphan-release',
            "lease",
        )


if __name__ == "__main__":
    main()
