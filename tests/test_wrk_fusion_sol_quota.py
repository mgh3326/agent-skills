"""Fixture-only wrk spawns prove Fusion-Sol arbiter quota routing."""

from __future__ import annotations

import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ADDRESS_SPACE_LIMIT = 2 * 1024 * 1024 * 1024


def _set_memory_limit(limit_kind: int) -> bool:
    try:
        _soft, hard = resource.getrlimit(limit_kind)
        cap = ADDRESS_SPACE_LIMIT if hard == resource.RLIM_INFINITY else min(ADDRESS_SPACE_LIMIT, hard)
        resource.setrlimit(limit_kind, (cap, cap))
        return True
    except (OSError, ValueError):
        return False


def limit_child_memory() -> None:
    # RLIMIT_AS is unavailable or rejected by some macOS Python builds. Its
    # data-segment limit still caps the fixture subprocess heap there.
    address_space = getattr(resource, "RLIMIT_AS", None)
    if address_space is not None and _set_memory_limit(address_space):
        return
    if not _set_memory_limit(resource.RLIMIT_DATA):
        raise RuntimeError("could not apply the fixture subprocess memory cap")


class FusionSolQuotaSpawnTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="fusion-sol-quota-")
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.xdg = {name: self.root / name.lower() for name in (
            "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME")}
        self.runtime = self.root / "runtime"
        for directory in (self.home, self.runtime, *self.xdg.values()):
            directory.mkdir(parents=True, exist_ok=True)
        trusted = self.xdg["XDG_DATA_HOME"] / "devin" / "cli" / "trusted_workspaces.json"
        trusted.parent.mkdir(parents=True)
        trusted.write_text(json.dumps({"trusted_paths": [str(self.root)]}), encoding="utf-8")
        self.cwd = self.root / "workspace"
        self.cwd.mkdir()
        self.brief = self.root / "brief.md"
        self.brief.write_text("Fixture-only quota routing check.\n", encoding="utf-8")
        self.inbox = self.root / "jobs"
        self.scopefuel_log = self.root / "scopefuel.log"
        self.launch_log = self.root / "launch.log"
        self.groups: list[tuple[int, Path]] = []

    def tearDown(self) -> None:
        for group, pidfile in self.groups:
            try:
                sentinel_pid = int(pidfile.read_text(encoding="utf-8").splitlines()[0])
                if os.getpgid(sentinel_pid) == group:
                    os.killpg(group, signal.SIGTERM)
            except (OSError, ValueError, IndexError):
                pass
        self.tmp.cleanup()

    def spawn(self, profile: str) -> dict:
        job = f"quota-{profile}"
        env = {
            "PATH": os.defpath,
            "HOME": str(self.home),
            "XDG_CACHE_HOME": str(self.xdg["XDG_CACHE_HOME"]),
            "XDG_CONFIG_HOME": str(self.xdg["XDG_CONFIG_HOME"]),
            "XDG_DATA_HOME": str(self.xdg["XDG_DATA_HOME"]),
            "XDG_STATE_HOME": str(self.xdg["XDG_STATE_HOME"]),
            "XDG_RUNTIME_DIR": str(self.runtime),
            "TMPDIR": str(self.root),
            "HK_TASK_ID": "1729",
            "ARBITER_INBOX_ROOT": str(self.inbox),
            "ARBITER_BIN": str(ROOT / "bin" / "arbiter"),
            "HANDOFFKEEP_BIN": str(self.root / "missing-handoffkeep-fixture"),
            "SCOPEFUEL_BIN": str(ROOT / "tests" / "fixtures" / "scopefuel"),
            "HERDR_BIN": str(ROOT / "tests" / "fixtures" / "herdr"),
            "WRK_NO_SLEEP": "1",
            "WRK_COMPLETION_INTERVAL_S": "3600",
            "WRK_FIXTURE_SCENARIO": "spawn",
            "WRK_FIXTURE_LOG": str(self.root / f"herdr-{profile}.log"),
            "WRK_SCOPEFUEL_LOG": str(self.scopefuel_log),
            "WRK_LAUNCH_LOG": str(self.launch_log),
            "WRK_REFRESH_TIMEOUT_S": "5",
            "WRK_HOSTS_CONFIG": str(self.root / "missing-hosts.toml"),
        }
        command = [
            str(ROOT / "bin" / "wrk"), "spawn", "-c", str(self.cwd), "-m", profile,
            "-p", str(self.brief), "-w", "w1", "-l", f"fixture-{profile}", "--t", "T2",
            "--task", "1729", "--task-hk-bypass", "--job", job,
        ]
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            preexec_fn=limit_child_memory,
        )
        self.groups.append((process.pid, self.inbox / job / "completion-sentinel.pid"))
        try:
            stdout, stderr = process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
            self.fail(f"fixture spawn timed out for {profile}")
        self.assertEqual(process.returncode, 0, f"{profile}: {stdout}\n{stderr}")
        event_dir = self.inbox / job / "events"
        records = sorted(event_dir.glob("*-quota_pool.record.json"))
        self.assertEqual(len(records), 1, f"{profile}: missing quota_pool record")
        return json.loads(records[0].read_text(encoding="utf-8"))

    def test_fusion_profiles_use_codex_and_other_devin_profiles_stay_devin(self) -> None:
        expected = {
            "devin-fusion-sol61": "codex",
            "devin-swe2": "devin",
            "devin-ds41": "devin",
        }
        for profile, pool in expected.items():
            with self.subTest(profile=profile):
                event = self.spawn(profile)
                payload = event["payload"]
                self.assertEqual(event["kind"], "quota_pool.record")
                self.assertEqual(payload["profile"], profile)
                self.assertEqual(payload["pool"], pool)
                self.assertEqual(payload["launch_profile"], profile)

        gate_calls = self.scopefuel_log.read_text(encoding="utf-8").splitlines()
        self.assertIn("gate -m devin-fusion-sol61", gate_calls)
        for profile in ("devin-swe2", "devin-ds41"):
            self.assertIn(f"gate -m {profile}", gate_calls)


if __name__ == "__main__":
    unittest.main(verbosity=2)
