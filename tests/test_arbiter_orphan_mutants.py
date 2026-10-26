#!/usr/bin/env python3
"""Prove the orphan-release assertions catch each named gc mutation."""

from collections.abc import Callable
import datetime as dt
import json
import os
from pathlib import Path
import sqlite3
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


def age_job(env: dict[str, str], job: str, minutes: int) -> None:
    created_at = (
        dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        - dt.timedelta(minutes=minutes)
    ).isoformat()
    db = Path(env["XDG_DATA_HOME"]) / "arbiter" / "state.db"
    with sqlite3.connect(db) as con:
        rows = con.execute(
            "SELECT seq, payload FROM events WHERE job_id = ?"
            " AND kind IN ('job.claim', 'job.reclaim', 'job.spawned')",
            (job,),
        ).fetchall()
        for seq, body in rows:
            event = json.loads(body)
            event["created_at"] = created_at
            con.execute(
                "UPDATE events SET created_at = ?, payload = ? WHERE job_id = ? AND seq = ?",
                (created_at, json.dumps(event, ensure_ascii=False, sort_keys=True), job, seq),
            )
        con.execute(
            "UPDATE jobs SET created_at = ?, updated_at = ? WHERE job_id = ?",
            (created_at, created_at, job),
        )


def drop_quota(env: dict[str, str], job: str) -> None:
    db = Path(env["XDG_DATA_HOME"]) / "arbiter" / "state.db"
    with sqlite3.connect(db) as con:
        con.execute("DELETE FROM quota_pool_records WHERE job_id = ?", (job,))


def make_released_job(
    root: Path, binary: Path, name: str
) -> tuple[dict[str, str], Path]:
    env, agents, job = seed(root, binary, name, None)
    age_job(env, job, 11)
    released = call(binary, env, "gc", "--herdr-agent-list", str(agents), "--json")
    if (
        released.returncode != 0
        or status(binary, env, job)["jobs"][0]["state"] != "released"
    ):
        raise AssertionError(f"setup failed to create old released job {job}: {released.stderr}")
    return env, agents


def reclaim_and_lease(binary: Path, env: dict[str, str], job: str) -> None:
    reclaimed = call(
        binary,
        env,
        "claim",
        "--reclaim-released",
        "--job",
        job,
        "--agent-label",
        f"{job}-agent",
        "--lane",
        "retry",
        "--t",
        "T1",
    )
    if reclaimed.returncode != 0:
        raise AssertionError(f"reclaim failed for {job}: {reclaimed.stderr}")
    gate = Path(env["ARBITER_INBOX_ROOT"]).parent / "gate.out"
    leased = call(
        binary,
        env,
        "lease",
        "--job",
        job,
        "--kind",
        "quota_pool",
        "--profile",
        "codex-max",
        "--gate-output",
        str(gate),
    )
    if leased.returncode != 0:
        raise AssertionError(f"quota lease failed for {job}: {leased.stderr}")


def run_herdr_fifo_race(
    root: Path,
    binary: Path,
    env: dict[str, str],
    command: tuple[str, ...],
    after_snapshot: Callable[[], None],
) -> subprocess.CompletedProcess[str]:
    fifo = root / "herdr-agents.fifo"
    os.mkfifo(fifo)
    process = subprocess.Popen(
        [str(binary), *command, "--herdr-agent-list", str(fifo), "--json"],
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    writer = os.open(fifo, os.O_WRONLY)
    problem: BaseException | None = None
    try:
        after_snapshot()
    except BaseException as exc:
        problem = exc
    finally:
        os.write(writer, b'{"result":{"agents":[]}}\n')
        os.close(writer)
    stdout, stderr = process.communicate()
    if problem is not None:
        raise problem
    return subprocess.CompletedProcess(
        process.args, process.returncode, stdout=stdout, stderr=stderr
    )


def assert_gc_skips_reclaimed_snapshot(root: Path, binary: Path, name: str) -> None:
    env, _agents = make_released_job(root, binary, name)

    def reclaim_and_age() -> None:
        reclaim_and_lease(binary, env, name)
        age_job(env, name, 11)

    gc = run_herdr_fifo_race(
        root,
        binary,
        env,
        ("gc",),
        reclaim_and_age,
    )
    current = status(binary, env, name)
    if gc.returncode != 0:
        raise AssertionError(f"gc failed in reclaim snapshot race: {gc.stderr}")
    if current["jobs"][0]["state"] != "leased" or not current["quota_pool_records"]:
        raise AssertionError(f"gc retired a job reclaimed after its Herdr snapshot: {current}")
    output = json.loads(gc.stdout)
    skipped = [row for row in output.get("skipped", []) if row.get("job_id") == name]
    if not skipped or "changed after Herdr snapshot" not in skipped[0].get("reason", ""):
        raise AssertionError(f"gc did not log the stale snapshot reason: {output}")
    if "gc skipped orphan cleanup" not in gc.stderr:
        raise AssertionError(f"gc omitted its stale snapshot log line: {gc.stderr}")
    if event_kinds(binary, env, name).count("job.orphan_release") != 1:
        raise AssertionError("gc wrote a second orphan release after reclaim")


def assert_force_refuses_reclaimed_snapshot(root: Path, binary: Path, name: str) -> None:
    env, _agents = make_released_job(root, binary, name)

    def reclaim_and_remove_quota() -> None:
        reclaim_and_lease(binary, env, name)
        drop_quota(env, name)
        age_job(env, name, 11)

    result = run_herdr_fifo_race(
        root,
        binary,
        env,
        ("release", "--force", "--job", name),
        reclaim_and_remove_quota,
    )
    current = status(binary, env, name)
    if result.returncode != 5 or "changed after Herdr snapshot" not in result.stderr:
        raise AssertionError(
            f"force release did not refuse the stale snapshot: rc={result.returncode} "
            f"stderr={result.stderr}"
        )
    if current["jobs"][0]["state"] != "leased" or current["quota_pool_records"]:
        raise AssertionError(f"force release changed the reclaimed job: {current}")
    if event_kinds(binary, env, name).count("job.orphan_release") != 1:
        raise AssertionError("force release wrote an orphan event after reclaim")


def event_kinds(binary: Path, env: dict[str, str], job: str) -> list[str]:
    result = call(binary, env, "job-get", "--job", job, "--json")
    if result.returncode != 0:
        raise AssertionError(f"job-get failed for {job}: {result.stderr}")
    return json.loads(result.stdout)["recent_event_kinds"]


def assert_gc_retains_listed_idle_agent(
    binary: Path, env: dict[str, str], agents: Path, job: str
) -> None:
    gc = call(binary, env, "gc", "--herdr-agent-list", str(agents), "--json")
    if gc.returncode != 0:
        raise AssertionError(f"gc failed for a listed idle agent: {gc.stderr}")
    current = status(binary, env, job)
    if current["jobs"][0]["state"] != "leased":
        raise AssertionError("gc released listed idle agent pane")
    if {row["job_id"] for row in current["quota_pool_records"]} != {job}:
        raise AssertionError("gc deleted quota capacity for a listed idle agent")
    if "job.orphan_release" in event_kinds(binary, env, job):
        raise AssertionError("gc wrote orphan_release for a listed idle agent")


def prove_working_only_mutant_goes_red(root: Path) -> None:
    control_env, control_agents, control_job = seed(
        root / "control", ARBITER_SOURCE, "idle-control", "idle"
    )
    age_job(control_env, control_job, 11)
    assert_gc_retains_listed_idle_agent(
        ARBITER_SOURCE, control_env, control_agents, control_job
    )

    mutant = mutate(
        root / "working-only-mutant",
        "gc-working-only",
        '            if any(status != "unknown" for status in statuses):\n'
        '                # Any exact listed agent with a known status owns its pane,\n'
        '                # whether it is working, idle, blocked, or done.\n'
        '                continue\n',
        '            if HERDR_LIVE_STATUS in statuses:\n'
        '                continue\n',
    )
    mutant_env, mutant_agents, mutant_job = seed(
        root / "mutant-state", mutant, "idle-mutant", "idle"
    )
    age_job(mutant_env, mutant_job, 11)
    try:
        assert_gc_retains_listed_idle_agent(
            mutant, mutant_env, mutant_agents, mutant_job
        )
    except AssertionError as exc:
        if str(exc) != "gc released listed idle agent pane":
            raise
    else:
        raise AssertionError("working-only gc mutant survived the idle-pane assertion")
    print("PASS mutant-gc-working-only-goes-red-on-idle")


def prove_startup_grace_mutant_goes_red(root: Path) -> None:
    control_env, control_agents, control_job = seed(
        root / "control", ARBITER_SOURCE, "young-control", None
    )
    age_job(control_env, control_job, 1)
    gc = call(
        ARBITER_SOURCE,
        control_env,
        "gc",
        "--herdr-agent-list",
        str(control_agents),
        "--json",
    )
    if (
        gc.returncode != 0
        or status(ARBITER_SOURCE, control_env, control_job)["jobs"][0]["state"]
        != "leased"
    ):
        raise AssertionError("startup grace control did not retain the young job")

    mutant = mutate(
        root / "startup-grace-mutant",
        "gc-no-startup-grace",
        '    if moment - max(claim_times) < ORPHAN_STARTUP_GRACE:\n'
        '        return "latest claim/reclaim is inside the 10-minute startup grace"\n',
        '    if False and moment - max(claim_times) < ORPHAN_STARTUP_GRACE:\n'
        '        return "latest claim/reclaim is inside the 10-minute startup grace"\n',
    )
    mutant_env, mutant_agents, mutant_job = seed(
        root / "mutant-state", mutant, "young-mutant", None
    )
    age_job(mutant_env, mutant_job, 1)
    gc = call(
        mutant,
        mutant_env,
        "gc",
        "--herdr-agent-list",
        str(mutant_agents),
        "--json",
    )
    if (
        gc.returncode != 0
        or status(mutant, mutant_env, mutant_job)["jobs"][0]["state"]
        != "released"
    ):
        raise AssertionError("startup-grace mutant did not release the young test job")

    force_env, force_agents, force_job = seed(
        root / "force-mutant-state", mutant, "young-force-mutant", None
    )
    drop_quota(force_env, force_job)
    age_job(force_env, force_job, 1)
    force = call(
        mutant,
        force_env,
        "release",
        "--force",
        "--job",
        force_job,
        "--herdr-agent-list",
        str(force_agents),
    )
    if (
        force.returncode != 0
        or status(mutant, force_env, force_job)["jobs"][0]["state"]
        != "released"
    ):
        raise AssertionError("startup-grace mutant did not release a young manual orphan")
    print("PASS mutant-without-claim-startup-grace-goes-red-on-gc-and-force-release")


def prove_snapshot_mutant_goes_red(root: Path) -> None:
    control_root = root / "control"
    control_root.mkdir(parents=True, exist_ok=True)
    assert_gc_skips_reclaimed_snapshot(control_root, ARBITER_SOURCE, "snapshot-control")

    mutant = mutate(
        root / "snapshot-mutant",
        "gc-ignores-job-snapshot",
        '    return before is not None and before == current\n',
        '    return True\n',
    )
    mutant_root = root / "mutant-state"
    mutant_root.mkdir(parents=True, exist_ok=True)
    try:
        assert_gc_skips_reclaimed_snapshot(mutant_root, mutant, "snapshot-mutant")
    except AssertionError as exc:
        if "retired a job reclaimed" not in str(exc):
            raise
    else:
        raise AssertionError("snapshot-check mutant survived the reclaimed-job assertion")
    print("PASS mutant-gc-ignores-job-snapshot-goes-red")

    force_root = root / "mutant-force-state"
    force_root.mkdir(parents=True, exist_ok=True)
    try:
        assert_force_refuses_reclaimed_snapshot(
            force_root, mutant, "snapshot-force-mutant"
        )
    except AssertionError as exc:
        if "force release did not refuse the stale snapshot" not in str(exc):
            raise
    else:
        raise AssertionError("snapshot-check mutant survived the manual release assertion")
    print("PASS mutant-force-ignores-job-snapshot-goes-red")


def exercise(root: Path, name: str, old: str, new: str, mode: str) -> None:
    binary = mutate(root, name, old, new)
    agent_status = "unknown" if mode == "unknown" else None
    env, agents, job = seed(
        root / "state-root", binary, f"orphan-{name}", agent_status,
        path_lease=(mode == "lease"),
    )
    age_job(env, job, 11)
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
        prove_working_only_mutant_goes_red(root / "working-only-proof")
        prove_startup_grace_mutant_goes_red(root / "startup-grace-proof")
        prove_snapshot_mutant_goes_red(root / "snapshot-proof")
        snapshot_root = root / "snapshot-tests"
        snapshot_root.mkdir(parents=True, exist_ok=True)
        assert_gc_skips_reclaimed_snapshot(
            snapshot_root / "gc", ARBITER_SOURCE, "snapshot-gc"
        )
        assert_force_refuses_reclaimed_snapshot(
            snapshot_root / "force", ARBITER_SOURCE, "snapshot-force"
        )
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
