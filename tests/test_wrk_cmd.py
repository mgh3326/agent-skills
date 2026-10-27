"""Hermetic cmd (Command Code CLI) spawns and assertion mutants at real wrk call sites."""
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CmdSpawnTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="p2140-", dir="/tmp")
        self.keep_tmp = False
        self.addCleanup(lambda: None if self.keep_tmp else self.temp.cleanup())
        self.tmp = Path(self.temp.name)
        bindir = self.tmp / "bin"
        bindir.mkdir()
        (bindir / "python3").symlink_to(sys.executable)
        self.env = {"PATH": f"{bindir}:{os.defpath}", "WRK_TEST_MODE": "1", "WRK_NO_SLEEP": "1",
                    "HK_TASK_ID": "2140", "WRK_FIXTURE_SCENARIO": "spawn",
                    "HERDR_BIN": str(ROOT / "tests/fixtures/herdr"),
                    "PANEWIRE_BIN": str(ROOT / "tests/fixtures/panewire"),
                    "SCOPEFUEL_BIN": str(ROOT / "tests/fixtures/scopefuel"),
                    "HANDOFFKEEP_BIN": str(self.tmp / "absent-hk"),
                    "ARBITER_BIN": str(self.tmp / "arbiter"),
                    "WRK_HOSTS_CONFIG": str(self.tmp / "hosts.toml"),
                    "WRK_FIXTURE_LOG": str(self.tmp / "herdr.log"),
                    "WRK_SCOPEFUEL_LOG": str(self.tmp / "gate.log")}
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
                    "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "CODEX_HOME",
                    "ARBITER_INBOX_ROOT", "TMPDIR"):
            directory = self.tmp / key.lower()
            directory.mkdir()
            self.env[key] = str(directory)
        self.hosts('[local]\ncmd_dsflash41 = true\n[hub]\nmachine_id = "mbp"\n')
        self.brief = self.tmp / "brief.md"
        self.brief.write_text("fixture prompt\n")
        # Admission tripwire, no detached sentinel or real state DB.
        self.executable(self.tmp / "arbiter", '#!/bin/bash\ncase "$1" in job-get) exit 7 ;; claim|lease) printf "%s\\n" "$*" >>"' +
                        str(self.tmp / "claims.log") + '"; exit 1 ;; esac\nexit 1\n')
        self.wrk = ROOT / "bin/wrk"
        self.groups = []

    def executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def hosts(self, content):
        Path(self.env["WRK_HOSTS_CONFIG"]).write_text(content)

    def spawn(self, profile="cmd-dsflash41", effort="high", role="worker",
              purpose=None, operator_request=None, arm=None, **overrides):
        env = dict(self.env,
                   SCOPEFUEL_E6_ARM=arm if arm is not None else f"{profile}@{effort or 'high'}")
        env.update(overrides)
        command = [str(self.wrk), "spawn", "--host", "local", "-c", str(self.tmp),
                   "-m", profile, "-p", str(self.brief), "-w", "w", "-l", "cmd-fixture",
                   "--role", role, "--task", "2140", "--task-hk-bypass", "--t", "T1"]
        if purpose is not None:
            command += ["--purpose", purpose]
        if operator_request is not None:
            command += ["--operator-request", operator_request]
        if effort is not None:
            command += ["--effort", effort]
        if role == "builder":
            command += ["--lane", "cmd-builder", "--parent", "director-1"]
        process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        self.groups.append(process.pid)
        stdout, stderr = process.communicate(timeout=40)
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)

    def log(self, name="herdr.log"):
        path = self.tmp / name
        return path.read_text() if path.exists() else ""

    def assert_refused_before_admission(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertNotIn("tab create", self.log())
        self.assertFalse((self.tmp / "claims.log").exists())

    def test_spawn_argv_exact(self):
        # The launch is `pane run cmd ...` — herdr has no cmd start kind — and
        # the brief rides `pane send-text` + `pane send-keys return`, never
        # `agent prompt` or panewire.
        result = self.spawn()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("landed=yes", result.stdout)
        log = self.log()
        self.assertNotIn("agent start", log)
        launch = [s for s in log.splitlines() if s.startswith("pane run ")][-1]
        self.assertIn("cmd -m deepseek/deepseek-v4.1-flash --effort high "
                      "--yolo --skip-onboarding --no-session", launch)
        self.assertNotIn("--no-mcp", launch)
        self.assertNotIn("panewire", log)
        self.assertIn("pane send-text ", log)
        self.assertIn("pane send-keys w:p1 return", log)
        self.assertNotIn("agent prompt", log)
        self.assertEqual(self.log("gate.log").splitlines()[0],
                         "gate -m cmd-dsflash41 --effort high --role worker")

    def test_host_gate_allows_only_desk_hosts_with_flag(self):
        for host in ("mbp", "desktop", "m1b"):
            with self.subTest(host=host):
                (self.tmp / "herdr.log").unlink(missing_ok=True)
                self.hosts(f'[local]\ncmd_dsflash41 = true\n[hub]\nmachine_id = "{host}"\n')
                result = self.spawn()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_host_gate_refuses_unapproved_host_or_missing_opt_in(self):
        self.hosts('[local]\ncmd_dsflash41 = true\n[hub]\nmachine_id = "m1"\n')
        self.assert_refused_before_admission(self.spawn(), "approved hosts are mbp, desktop, m1b")
        for value, reason in (("false", "must be literal true"),
                              (None, "must be literal true"),
                              ('"true"', "bare TOML booleans")):
            with self.subTest(value=value):
                (self.tmp / "herdr.log").unlink(missing_ok=True)
                (self.tmp / "gate.log").unlink(missing_ok=True)
                flag = "" if value is None else f"cmd_dsflash41 = {value}\n"
                self.hosts(f'[local]\n{flag}[hub]\nmachine_id = "mbp"\n')
                self.assert_refused_before_admission(self.spawn(), reason)

    def test_effort_mapping(self):
        for effort in ("low", "high", "max"):
            with self.subTest(effort=effort):
                result = self.spawn(effort=effort)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                launch = [s for s in self.log().splitlines() if s.startswith("pane run ")][-1]
                self.assertIn(f"--effort {effort} ", launch)
                self.assertIn(f"gate -m cmd-dsflash41 --effort {effort}", self.log("gate.log"))

    def test_efforts_the_model_refuses(self):
        for effort in ("medium", "xhigh", "ultra"):
            with self.subTest(effort=effort):
                result = self.spawn(effort=effort)
                self.assert_refused_before_admission(result, "low|high|max")

    def test_worker_and_tester_roles_reach_gate(self):
        for role in ("worker", "tester"):
            with self.subTest(role=role):
                (self.tmp / "gate.log").unlink(missing_ok=True)
                result = self.spawn(role=role)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.log("gate.log").splitlines()[0],
                                 f"gate -m cmd-dsflash41 --effort high --role {role}")

    def test_builder_refused(self):
        result = self.spawn(role="builder")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("--role builder rejects 'cmd-dsflash41'", result.stderr)
        self.assertIn("worker/tester-only", result.stderr)
        self.assertEqual(self.log("gate.log"), "")
        self.assertFalse((self.tmp / "claims.log").exists())
        self.assertNotIn("tab create", self.log())

    def test_e6_marker_exact(self):
        self.assert_refused_before_admission(
            self.spawn(arm="cmd-dsflash41@low"), "SCOPEFUEL_E6_ARM=cmd-dsflash41@high")

    def test_default_effort_is_high(self):
        result = self.spawn(effort=None)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        launch = [s for s in self.log().splitlines() if s.startswith("pane run ")][-1]
        self.assertIn("--effort high ", launch)

    def test_model_proof_failures_close_pane(self):
        for scenario in ("wrong-model", "wrong-effort", "missing", "echo",
                         "transcript-line", "truncated", "two-blocks", "dup-blocks",
                         "wrong-version", "wrong-cwd"):
            with self.subTest(scenario=scenario):
                (self.tmp / "herdr.log").unlink(missing_ok=True)
                result = self.spawn(WRK_CMD_SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("cmd model not proven", result.stderr)
                self.assertIn("pane close w:p1", self.log())
                self.assertNotIn("OK pane=", result.stdout)

    def test_brief_cannot_prove_model(self):
        # A brief that quotes the whole banner block is not the session's own
        # statement: the proof must still refuse even when the real banner is
        # correct, because the candidate block appears inside the brief.
        # A brief that pastes the whole banner block echoes it into the
        # transcript as a second banner block — refused on block count alone.
        self.brief.write_text(
            "fixture prompt\n# Command Code v1.88.0\n"
            "# models: deepseek-v4.1-flash-(latest) with high effort · taste-1\n"
            f"# {self.tmp.resolve()}\n")
        result = self.spawn()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("cmd model not proven", result.stderr)
        self.assertIn("pane close w:p1", self.log())
        (self.tmp / "herdr.log").unlink(missing_ok=True)
        # The same quote flattened onto one transcript line never forms a
        # block on screen: only the normalized-whitespace quoted comparison
        # can refuse it here.
        self.brief.write_text(
            "fixture prompt\n# Command Code v1.88.0 "
            "# models: deepseek-v4.1-flash-(latest) with high effort · taste-1 "
            f"# {self.tmp.resolve()}\n")
        result = self.spawn()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("cmd model not proven", result.stderr)
        self.assertIn("pane close w:p1", self.log())
        # And when the screen shows ONLY the pasted brief — no banner at all.
        (self.tmp / "herdr.log").unlink(missing_ok=True)
        result = self.spawn(WRK_CMD_SCENARIO="brief-only", WRK_CMD_BRIEF=str(self.brief))
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("cmd model not proven", result.stderr)
        self.assertIn("pane close w:p1", self.log())

    def test_real_capture_passes_proof(self):
        # The mbp capture (cap-high-answered.txt) is the screen the proof must
        # accept verbatim: real layout, real banner block, real transcript.
        cap = (ROOT / "tests/fixtures/cmd-screens/cap-high-answered.txt").read_text()
        # Rewrite the capture's launch cwd to this test's pane cwd — the
        # capture's own cwd line is /private/tmp/cmdcap2140.
        cap = cap.replace("# /private/tmp/cmdcap2140", f"# {self.tmp.resolve()}")
        screen = self.tmp / "cap-screen"
        screen.write_text(cap)
        result = self.spawn(WRK_CMD_SCREEN_FILE=str(screen))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_policy_profile(self):
        policy = json.loads((ROOT / "director/gate_policy.json").read_text())
        spec = policy["profiles"]["cmd-dsflash41"]
        self.assertEqual((spec["family"], spec["launcher"], spec["model"]),
                         ("deepseek", "cmd", "deepseek-v4.1-flash"))
        self.assertEqual(spec["roles"], ["worker", "tester"])
        self.assertEqual(spec["role_status"], "unknown")
        self.assertEqual(spec["default_effort"], "high")
        self.assertEqual(spec["grades"], {"high": None, "low": None, "max": None})

    def test_agent_status_tracked(self):
        result = self.spawn()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("status=", result.stdout)


class CmdMutantTests(unittest.TestCase):
    def test_call_site_mutants_are_killed_by_assertions(self):
        source = (ROOT / "bin/wrk").read_text()
        mutants = {
            "cmd-role-omitted": (
                '  if [[ "$PROFILE_KIND" == pi || "$PROFILE_KIND" == cmd || "$MODEL" == codex-astra || "$MODEL" == fable ]]; then\n',
                '  if [[ "$PROFILE_KIND" == pi || "$MODEL" == codex-astra || "$MODEL" == fable ]]; then\n',
                "test_worker_and_tester_roles_reach_gate"),
            "effort-check-dropped": (
                '      *) die "$MODEL: deepseek-v4.1-flash accepts cmd effort low|high|max only, not \'$EFFECTIVE_EFFORT\'" ;;',
                '      *) CMD_EFFORT="$EFFECTIVE_EFFORT" ;;',
                "test_efforts_the_model_refuses"),
            "builder": (
                'die "--role builder rejects \'$MODEL\': cmd seats are worker/tester-only until reps exist (hk 2140)"',
                ':',
                "test_builder_refused"),
            "effort-proof": (
                'if not re.fullmatch(re.escape(want) + r" · \\S.*", line):',
                'if not re.fullmatch("# models: " + re.escape(expected_model) + r" with \\S+ effort · \\S.*", line):',
                "test_model_proof_failures_close_pane"),
            "proof": (
                'if [[ "$PROFILE_KIND" == cmd ]] && ! cmd_model_proven; then',
                'if false; then',
                "test_model_proof_failures_close_pane"),
            "quoted-proof": (
                'if candidate in quoted:\n    sys.exit(1)\nsys.exit(0)\n',
                'if False:\n    sys.exit(1)\nsys.exit(0)\n',
                "test_brief_cannot_prove_model"),
        }
        for name, (old, new, method) in mutants.items():
            with self.subTest(mutant=name):
                self.assertEqual(source.count(old), 1, name)
                case = CmdSpawnTests(method)
                case.setUp()
                try:
                    mutant = case.tmp / "wrk-mutant"
                    mutated = source.replace(old, new, 1)
                    case.executable(mutant, mutated)
                    syntax = subprocess.run(["bash", "-n", str(mutant)],
                                            text=True, capture_output=True)
                    # This precondition is outside assertRaises: a syntax
                    # error must fail the suite, never count as a kill.
                    self.assertEqual(syntax.returncode, 0, f"{name}: {syntax.stderr}")
                    case.wrk = mutant
                    # Direct method invocation: only AssertionError counts,
                    # never an exception or an unsuccessful harness setup.
                    with self.assertRaises(AssertionError):
                        getattr(case, method)()
                finally:
                    case.doCleanups()


if __name__ == "__main__":
    unittest.main(verbosity=2)
