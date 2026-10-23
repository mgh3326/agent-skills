"""Fixture-only wrk spawns prove Fusion-Sol arbiter quota routing."""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


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
            "WRK_TEST_MODE": "1",
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

    def launched_model(self, profile: str) -> str:
        executed = (self.root / f"herdr-{profile}.log.executed").read_text(encoding="utf-8")
        launches = [line.split() for line in executed.splitlines()
                    if line.split()[:1] == ["devin"]]
        self.assertEqual(len(launches), 1, f"{profile}: {executed}")
        argv = launches[0]
        self.assertEqual(argv.count("--model"), 1, argv)
        return argv[argv.index("--model") + 1]

    def test_xhigh_gates_as_itself_on_codex(self) -> None:
        # hk 1729 r2 B4: the xhigh spelling gates at its own catalog row and
        # records the codex pool, never devin-swe2 or the devin pool.
        profile = "devin-fusion-sol61-xhigh"
        payload = self.spawn(profile)["payload"]
        self.assertEqual((payload["profile"], payload["pool"], payload["launch_profile"]),
                         (profile, "codex", profile))
        self.assertEqual(self.scopefuel_log.read_text(encoding="utf-8").splitlines()[0],
                         f"gate -m {profile}")
        herdr = (self.root / f"herdr-{profile}.log").read_text(encoding="utf-8")
        self.assertIn("--env ARBITER_RESOURCE=codex ", herdr)
        self.assertIn(f"--env ARBITER_PROFILE={profile} ", herdr)

    def test_launch_argv_never_uses_a_fast_model(self) -> None:
        # hk 1729 decision: -fast bills Devin quota, so neither spelling may
        # launch a -fast id in any position (suffix or infix).
        expected = {
            "devin-fusion-sol61": "fusion-gpt-6-1-sol-high-sidekick-swe-2-medium",
            "devin-fusion-sol61-xhigh": "fusion-gpt-6-1-sol-xhigh-sidekick-swe-2-medium",
        }
        for profile, model in expected.items():
            with self.subTest(profile=profile):
                self.spawn(profile)
                launched = self.launched_model(profile)
                self.assertNotIn("-fast", launched.casefold())
                self.assertFalse(launched.casefold().endswith("fast"), launched)
                self.assertEqual(launched, model)


if __name__ == "__main__":
    unittest.main(verbosity=2)
