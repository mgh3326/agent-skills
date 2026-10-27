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


def drop_path_leases(env: dict[str, str], job: str) -> None:
    db = Path(env["XDG_DATA_HOME"]) / "arbiter" / "state.db"
    with sqlite3.connect(db) as con:
        con.execute("DELETE FROM leases WHERE job_id = ? AND kind = 'path'", (job,))


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


def assert_gc_skips_reclaimed_snapshot(
    root: Path, binary: Path, name: str, *, rowless: bool = False
) -> None:
    env, _agents = make_released_job(root, binary, name)

    def reclaim_and_age() -> None:
        reclaim_and_lease(binary, env, name)
        if rowless:
            drop_quota(env, name)
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
    if current["jobs"][0]["state"] != "leased":
        raise AssertionError(f"gc retired a job reclaimed after its Herdr snapshot: {current}")
    if rowless and current["quota_pool_records"]:
        raise AssertionError(f"row-less reclaim race unexpectedly kept quota rows: {current}")
    if not rowless and not current["quota_pool_records"]:
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


def assert_gc_releases_rowless(binary: Path, env: dict[str, str], agents: Path,
                               job: str) -> None:
    gc = call(binary, env, "gc", "--herdr-agent-list", str(agents), "--json")
    current = status(binary, env, job)
    if gc.returncode != 0:
        raise AssertionError(f"gc failed for row-less job {job}: {gc.stderr}")
    if current["jobs"][0]["state"] != "released":
        raise AssertionError(f"gc did not release row-less job {job}: {current}")
    if current["quota_pool_records"] or current["leases"]:
        raise AssertionError(f"row-less gc release left resources for {job}: {current}")
    if event_kinds(binary, env, job).count("job.orphan_release") != 1:
        raise AssertionError(f"gc did not write exactly one row-less orphan event: {job}")
    event_dir = Path(env["ARBITER_INBOX_ROOT"]) / job / "events"
    events = [json.loads(path.read_text(encoding="utf-8"))
              for path in event_dir.glob("*.json")]
    orphan = [event for event in events if event.get("kind") == "job.orphan_release"]
    if (len(orphan) != 1 or orphan[0]["payload"].get("forced") is not False
            or orphan[0]["payload"].get("reason") != "job absent from herdr agent list"):
        raise AssertionError(f"row-less orphan event lacks permanent gc evidence: {orphan}")
    reclaimed = call(
        binary, env, "claim", "--reclaim-released", "--job", job,
        "--agent-label", f"{job}-agent", "--lane", "retry", "--t", "T1",
    )
    if reclaimed.returncode != 0:
        raise AssertionError(f"released row-less job could not be reclaimed: {reclaimed.stderr}")
    if event_kinds(binary, env, job).count("job.reclaim") != 1:
        raise AssertionError("row-less gc release did not permit one reclaim")


def assert_gc_retains_rowless_listed(binary: Path, env: dict[str, str],
                                     agents: Path, job: str) -> None:
    gc = call(binary, env, "gc", "--herdr-agent-list", str(agents), "--json")
    if gc.returncode != 0:
        raise AssertionError(f"gc refused a known listed row-less agent: {gc.stderr}")
    current = status(binary, env, job)
    if current["jobs"][0]["state"] != "leased":
        raise AssertionError("gc released listed row-less agent pane")
    if current["quota_pool_records"]:
        raise AssertionError("row-less test unexpectedly restored a quota row")
    if "job.orphan_release" in event_kinds(binary, env, job):
        raise AssertionError("gc wrote orphan_release for a listed row-less agent")


def assert_rowless_gc_guards(root: Path, binary: Path) -> None:
    # Earlier gc removed the quota row, but the path lease kept the job leased.
    # Once the path lease is gone, the next gc must release that row-less job.
    env, agents, job = seed(root / "prior-cleanup", binary, "prior-cleanup-rowless",
                            None, path_lease=True)
    age_job(env, job, 11)
    first_gc = call(binary, env, "gc", "--herdr-agent-list", str(agents), "--json")
    first_state = status(binary, env, job)
    if (first_gc.returncode != 0 or first_state["jobs"][0]["state"] != "leased"
            or first_state["quota_pool_records"]):
        raise AssertionError(f"prior gc did not leave a row-less leased job: {first_state}")
    drop_path_leases(env, job)
    assert_gc_releases_rowless(binary, env, agents, job)

    # A remaining path lease is still a blocker, even after the quota row is gone.
    path_env, path_agents, path_job = seed(
        root / "path-left", binary, "rowless-path-left", None, path_lease=True
    )
    drop_quota(path_env, path_job)
    age_job(path_env, path_job, 11)
    path_gc = call(binary, path_env, "gc", "--herdr-agent-list", str(path_agents), "--json")
    path_state = status(binary, path_env, path_job)
    if (path_gc.returncode != 0 or path_state["jobs"][0]["state"] != "leased"
            or len(path_state["leases"]) != 1
            or "job.orphan_release" in event_kinds(binary, path_env, path_job)):
        raise AssertionError(f"row-less gc ignored a remaining path lease: {path_state}")

    # The shared guard checks the latest claim/reclaim and the latest spawn.
    young_env, young_agents, young_job = seed(
        root / "young-claim", binary, "rowless-young-claim", None
    )
    drop_quota(young_env, young_job)
    age_job(young_env, young_job, 1)
    young_gc = call(binary, young_env, "gc", "--herdr-agent-list", str(young_agents), "--json")
    young_skips = json.loads(young_gc.stdout).get("skipped", []) if young_gc.returncode == 0 else []
    if (young_gc.returncode != 0 or status(binary, young_env, young_job)["jobs"][0]["state"]
            != "leased" or not any(row.get("job_id") == young_job and
                                    "10-minute startup grace" in row.get("reason", "")
                                    for row in young_skips)
            or "gc skipped orphan cleanup" not in young_gc.stderr):
        raise AssertionError(f"row-less claim startup grace was not logged: {young_gc.stderr}")

    spawn_env, spawn_agents, spawn_job = seed(
        root / "young-spawn", binary, "rowless-young-spawn", None
    )
    age_job(spawn_env, spawn_job, 11)
    spawned = call(binary, spawn_env, "event", "--job", spawn_job,
                   "--kind", "job.spawned", "--payload-json", '{"pane_id":"w:p-new"}')
    if spawned.returncode != 0:
        raise AssertionError(f"spawn receipt fixture failed: {spawned.stderr}")
    drop_quota(spawn_env, spawn_job)
    spawn_gc = call(binary, spawn_env, "gc", "--herdr-agent-list", str(spawn_agents), "--json")
    spawn_skips = json.loads(spawn_gc.stdout).get("skipped", []) if spawn_gc.returncode == 0 else []
    if (spawn_gc.returncode != 0 or status(binary, spawn_env, spawn_job)["jobs"][0]["state"]
            != "leased" or not any(row.get("job_id") == spawn_job and
                                    "latest spawn is inside" in row.get("reason", "")
                                    for row in spawn_skips)):
        raise AssertionError(f"row-less spawn startup grace was not honored: {spawn_gc.stderr}")

    for index, agent_status in enumerate(("idle", "done", "blocked", "working")):
        listed_env, listed_agents, listed_job = seed(
            root / f"listed-{index}", binary, f"rowless-listed-{agent_status}", agent_status
        )
        drop_quota(listed_env, listed_job)
        age_job(listed_env, listed_job, 11)
        assert_gc_retains_rowless_listed(binary, listed_env, listed_agents, listed_job)

    unknown_env, unknown_agents, unknown_job = seed(
        root / "unknown", binary, "rowless-unknown", "unknown"
    )
    drop_quota(unknown_env, unknown_job)
    age_job(unknown_env, unknown_job, 11)
    unknown_gc = call(binary, unknown_env, "gc", "--herdr-agent-list",
                      str(unknown_agents), "--json")
    if (unknown_gc.returncode != 6
            or status(binary, unknown_env, unknown_job)["jobs"][0]["state"] != "leased"
            or "unknown" not in unknown_gc.stderr
            or "job.orphan_release" in event_kinds(binary, unknown_env, unknown_job)):
        raise AssertionError(f"row-less unknown identity did not refuse gc: {unknown_gc.stderr}")

    unmapped_env, unmapped_agents, unmapped_job = seed(
        root / "unmapped", binary, "rowless-unmapped", None
    )
    drop_quota(unmapped_env, unmapped_job)
    age_job(unmapped_env, unmapped_job, 11)
    db = Path(unmapped_env["XDG_DATA_HOME"]) / "arbiter" / "state.db"
    with sqlite3.connect(db) as con:
        rows = con.execute(
            "SELECT seq, payload FROM events WHERE job_id = ? AND kind = 'job.claim'",
            (unmapped_job,),
        ).fetchall()
        for seq, body in rows:
            event = json.loads(body)
            event["payload"].pop("agent_label", None)
            con.execute("UPDATE events SET payload = ? WHERE job_id = ? AND seq = ?",
                        (json.dumps(event), unmapped_job, seq))
    unmapped_gc = call(binary, unmapped_env, "gc", "--herdr-agent-list",
                       str(unmapped_agents), "--json")
    if (unmapped_gc.returncode != 6
            or status(binary, unmapped_env, unmapped_job)["jobs"][0]["state"] != "leased"
            or "unmapped" not in unmapped_gc.stderr):
        raise AssertionError(f"row-less unmapped identity did not refuse gc: {unmapped_gc.stderr}")


def assert_gc_preview_mixes_rowless_and_listed(root: Path, binary: Path) -> None:
    env, empty_agents, first_job = seed(
        root / "state", binary, "preview-00", None, path_lease=True
    )
    jobs = [first_job]
    gate = Path(env["ARBITER_INBOX_ROOT"]).parent / "gate.out"
    for index in range(1, 12):
        job = f"preview-{index:02d}"
        claimed = call(binary, env, "claim", "--job", job, "--agent-label",
                       f"{job}-agent", "--lane", "live", "--t", "T1")
        leased = call(binary, env, "lease", "--job", job, "--kind", "quota_pool",
                      "--profile", "codex-max", "--gate-output", str(gate))
        path_lease = call(binary, env, "lease", "--job", job, "--resource",
                          f"path-{job}", "--kind", "path")
        if claimed.returncode or leased.returncode or path_lease.returncode:
            raise AssertionError(f"preview fixture setup failed for {job}")
        jobs.append(job)
    for job in jobs:
        age_job(env, job, 11)
    first_gc = call(binary, env, "gc", "--herdr-agent-list", str(empty_agents), "--json")
    if first_gc.returncode != 0:
        raise AssertionError(f"preview pre-cleanup gc failed: {first_gc.stderr}")
    for job in jobs:
        drop_path_leases(env, job)

    listed = {"preview-00": "idle", "preview-01": "done",
              "preview-02": "blocked", "preview-03": "working"}
    agents = Path(env["ARBITER_INBOX_ROOT"]).parent / "preview-agents.json"
    agents.write_text(json.dumps({"result": {"agents": [
        {"name": f"{job}-agent", "agent_status": agent_status}
        for job, agent_status in listed.items()
    ]}}), encoding="utf-8")
    gc = call(binary, env, "gc", "--herdr-agent-list", str(agents), "--json")
    if gc.returncode != 0:
        raise AssertionError(f"preview row-less gc failed: {gc.stderr}")
    released = {row["job_id"] for row in json.loads(gc.stdout)["orphan_released"]}
    expected = set(jobs) - set(listed)
    if released != expected:
        raise AssertionError(f"preview released {sorted(released)}, expected {sorted(expected)}")
    for job in jobs:
        state = status(binary, env, job)["jobs"][0]["state"]
        if state != ("leased" if job in listed else "released"):
            raise AssertionError(f"preview wrong state for {job}: {state}")


def prove_idle_is_gone_mutant_goes_red(root: Path) -> None:
    control_env, control_agents, control_job = seed(
        root / "control", ARBITER_SOURCE, "idle-control", "idle"
    )
    age_job(control_env, control_job, 11)
    assert_gc_retains_listed_idle_agent(
        ARBITER_SOURCE, control_env, control_agents, control_job
    )

    mutant = mutate(
        root / "idle-as-gone-mutant",
        "gc-idle-is-gone",
        '            if any(status != "unknown" for status in statuses):\n',
        '            if any(status in {"working", "blocked", "done"} for status in statuses):\n',
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
        raise AssertionError("idle-as-gone gc mutant survived the idle-pane assertion")

    rowless_env, rowless_agents, rowless_job = seed(
        root / "rowless-control", ARBITER_SOURCE, "idle-rowless-control", "idle"
    )
    drop_quota(rowless_env, rowless_job)
    age_job(rowless_env, rowless_job, 11)
    assert_gc_retains_rowless_listed(
        ARBITER_SOURCE, rowless_env, rowless_agents, rowless_job
    )
    rowless_mutant_env, rowless_mutant_agents, rowless_mutant_job = seed(
        root / "rowless-mutant-state", mutant, "idle-rowless-mutant", "idle"
    )
    drop_quota(rowless_mutant_env, rowless_mutant_job)
    age_job(rowless_mutant_env, rowless_mutant_job, 11)
    try:
        assert_gc_retains_rowless_listed(
            mutant, rowless_mutant_env, rowless_mutant_agents, rowless_mutant_job
        )
    except AssertionError as exc:
        if str(exc) != "gc released listed row-less agent pane":
            raise
    else:
        raise AssertionError("idle-as-gone gc mutant survived the row-less idle assertion")
    print("PASS mutant-gc-treats-idle-as-gone-goes-red-on-quota-and-rowless-jobs")


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
    if "10-minute startup grace" not in gc.stderr:
        raise AssertionError("quota-backed startup grace skip was not logged")

    mutant = mutate(
        root / "startup-grace-mutant",
        "gc-no-startup-grace",
        "            startup_blocker = _orphan_startup_blocker(con, job_id, moment)\n",
        "            startup_blocker = None\n",
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

    rowless_control_env, rowless_agents, rowless_job = seed(
        root / "rowless-control", ARBITER_SOURCE, "young-rowless-control", None
    )
    drop_quota(rowless_control_env, rowless_job)
    age_job(rowless_control_env, rowless_job, 1)
    rowless_gc = call(
        ARBITER_SOURCE, rowless_control_env, "gc", "--herdr-agent-list",
        str(rowless_agents), "--json",
    )
    if (rowless_gc.returncode != 0
            or status(ARBITER_SOURCE, rowless_control_env, rowless_job)["jobs"][0]["state"]
            != "leased"
            or "10-minute startup grace" not in rowless_gc.stderr):
        raise AssertionError("row-less startup grace control did not retain and log the young job")
    rowless_mutant_env, rowless_mutant_agents, rowless_mutant_job = seed(
        root / "rowless-mutant-state", mutant, "young-rowless-mutant", None
    )
    drop_quota(rowless_mutant_env, rowless_mutant_job)
    age_job(rowless_mutant_env, rowless_mutant_job, 1)
    rowless_gc = call(
        mutant, rowless_mutant_env, "gc", "--herdr-agent-list",
        str(rowless_mutant_agents), "--json",
    )
    if (rowless_gc.returncode != 0
            or status(mutant, rowless_mutant_env, rowless_mutant_job)["jobs"][0]["state"]
            != "released"):
        raise AssertionError(
            "row-less startup-grace call-site mutant did not release the young job"
        )

    force_control_env, force_agents, force_job = seed(
        root / "force-control", ARBITER_SOURCE, "young-force-control", None
    )
    drop_quota(force_control_env, force_job)
    age_job(force_control_env, force_job, 1)
    force_control = call(
        ARBITER_SOURCE, force_control_env, "release", "--force", "--job", force_job,
        "--herdr-agent-list", str(force_agents),
    )
    if (force_control.returncode != 5
            or "10-minute startup grace" not in force_control.stderr
            or status(ARBITER_SOURCE, force_control_env, force_job)["jobs"][0]["state"]
            != "leased"):
        raise AssertionError("force-release startup grace control did not refuse the young job")
    force_mutant = mutate(
        root / "force-startup-grace-mutant",
        "force-no-startup-grace",
        "            startup_blocker = _orphan_startup_blocker(con, args.job, moment)\n",
        "            startup_blocker = None\n",
    )
    force_mutant_env, force_mutant_agents, force_mutant_job = seed(
        root / "force-mutant-state", force_mutant, "young-force-mutant", None
    )
    drop_quota(force_mutant_env, force_mutant_job)
    age_job(force_mutant_env, force_mutant_job, 1)
    force = call(
        force_mutant, force_mutant_env, "release", "--force", "--job", force_mutant_job,
        "--herdr-agent-list", str(force_mutant_agents),
    )
    if (force.returncode != 0
            or status(force_mutant, force_mutant_env, force_mutant_job)["jobs"][0]["state"]
            != "released"):
        raise AssertionError(
            "force-release startup-grace call-site mutant did not release the young job"
        )
    print("PASS mutant-without-claim-startup-grace-goes-red-on-gc-and-force-release")


def prove_rowless_candidate_mutant_goes_red(root: Path) -> None:
    control_env, control_agents, control_job = seed(
        root / "control", ARBITER_SOURCE, "rowless-control", None
    )
    drop_quota(control_env, control_job)
    age_job(control_env, control_job, 11)
    assert_gc_releases_rowless(ARBITER_SOURCE, control_env, control_agents, control_job)

    mutant = mutate(
        root / "rowless-candidate-mutant",
        "gc-drops-rowless-candidates",
        '            " AND NOT EXISTS (SELECT 1 FROM quota_pool_records AS q WHERE q.job_id = j.job_id)"\n',
        '            " AND EXISTS (SELECT 1 FROM quota_pool_records AS q WHERE q.job_id = j.job_id)"\n',
    )
    mutant_env, mutant_agents, mutant_job = seed(
        root / "mutant-state", mutant, "rowless-mutant", None
    )
    drop_quota(mutant_env, mutant_job)
    age_job(mutant_env, mutant_job, 11)
    try:
        assert_gc_releases_rowless(mutant, mutant_env, mutant_agents, mutant_job)
    except AssertionError as exc:
        if "gc did not release row-less job" not in str(exc):
            raise
    else:
        raise AssertionError("row-less candidate mutant survived the release assertion")
    print("PASS mutant-gc-drops-rowless-candidates-goes-red")


def prove_snapshot_mutant_goes_red(root: Path) -> None:
    control_root = root / "control"
    control_root.mkdir(parents=True, exist_ok=True)
    assert_gc_skips_reclaimed_snapshot(control_root, ARBITER_SOURCE, "snapshot-control")
    rowless_control_root = root / "rowless-control"
    rowless_control_root.mkdir(parents=True, exist_ok=True)
    assert_gc_skips_reclaimed_snapshot(
        rowless_control_root, ARBITER_SOURCE, "snapshot-rowless-control", rowless=True
    )

    mutant = mutate(
        root / "snapshot-mutant",
        "gc-ignores-job-snapshot",
        '            if not _job_claim_snapshot_matches(snapshots.get(job_id), current_snapshot):\n',
        '            if False and not _job_claim_snapshot_matches(snapshots.get(job_id), current_snapshot):\n',
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

    rowless_mutant_root = root / "rowless-mutant-state"
    rowless_mutant_root.mkdir(parents=True, exist_ok=True)
    try:
        assert_gc_skips_reclaimed_snapshot(
            rowless_mutant_root, mutant, "snapshot-rowless-mutant", rowless=True
        )
    except AssertionError as exc:
        if "retired a job reclaimed" not in str(exc):
            raise
    else:
        raise AssertionError(
            "snapshot call-site mutant survived the row-less reclaimed-job assertion"
        )

    force_control_root = root / "force-control"
    force_control_root.mkdir(parents=True, exist_ok=True)
    assert_force_refuses_reclaimed_snapshot(
        force_control_root, ARBITER_SOURCE, "snapshot-force-control"
    )
    force_mutant = mutate(
        root / "force-snapshot-mutant",
        "force-ignores-job-snapshot",
        "_job_claim_snapshot_matches(\n            snapshot, current_snapshot\n        )",
        "True",
    )
    force_root = root / "mutant-force-state"
    force_root.mkdir(parents=True, exist_ok=True)
    try:
        assert_force_refuses_reclaimed_snapshot(
            force_root, force_mutant, "snapshot-force-mutant"
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
        assert_rowless_gc_guards(root / "rowless-guards", ARBITER_SOURCE)
        assert_gc_preview_mixes_rowless_and_listed(root / "preview", ARBITER_SOURCE)
        prove_rowless_candidate_mutant_goes_red(root / "rowless-candidate-proof")
        prove_idle_is_gone_mutant_goes_red(root / "idle-is-gone-proof")
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
