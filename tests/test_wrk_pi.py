"""Hermetic pi spawns and assertion mutants at real wrk call sites."""
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {f"pi-{name}55": f"anthropic/claude-{name}-5-5"
            for name in ("haiku", "sonnet", "opus")}


class PiSpawnTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="p2080-", dir="/tmp")
        self.keep_tmp = False
        self.addCleanup(lambda: None if self.keep_tmp else self.temp.cleanup())
        self.tmp = Path(self.temp.name)
        bindir = self.tmp / "bin"
        bindir.mkdir()
        (bindir / "python3").symlink_to(sys.executable)
        self.env = {"PATH": f"{bindir}:{os.defpath}", "WRK_TEST_MODE": "1", "WRK_NO_SLEEP": "1",
                    "HK_TASK_ID": "2080", "WRK_FIXTURE_SCENARIO": "spawn",
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
        self.hosts('[local]\npi_anthropic = true\n[hub]\nmachine_id = "fixture-host"\n')
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

    def spawn(self, profile="pi-sonnet55", effort="high", role="worker", **overrides):
        env = dict(self.env, SCOPEFUEL_E6_ARM=f"{profile}@{effort or 'high'}")
        env.update(overrides)
        command = [str(self.wrk), "spawn", "--host", "local", "-c", str(self.tmp),
                   "-m", profile, "-p", str(self.brief), "-w", "w", "-l", "pi-fixture",
                   "--role", role, "--task", "2080", "--task-hk-bypass", "--t", "T1"]
        if effort is not None:
            command += ["--effort", effort]
        if role == "builder":
            command += ["--lane", "pi-builder", "--parent", "director-1"]
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
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, result.stderr)
        self.assertNotIn("tab create", self.log())
        self.assertFalse((self.tmp / "claims.log").exists())

    def test_argv_gate_mapping_and_no_mcp(self):
        for effort in ("low", "medium", "high", "xhigh", "max"):
            with self.subTest(effort=effort):
                result = self.spawn(effort=effort)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("landed=yes", result.stdout)
                launch = [s for s in self.log().splitlines() if s.startswith("agent start ")][-1]
                self.assertIn("--kind pi ", launch)
                self.assertIn(f"--model anthropic/claude-sonnet-5-5:{effort}", launch)
                self.assertIn("--no-mcp", launch)
                self.assertIn(f"gate -m pi-sonnet55 --effort {effort}", self.log("gate.log"))
                self.assertNotIn("send-keys", self.log())

    def test_profiles_and_defaults(self):
        for profile, model in PROFILES.items():
            with self.subTest(profile=profile):
                result = self.spawn(profile=profile, effort=None,
                                    SCOPEFUEL_E6_ARM=f"{profile}@high")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"--model {model}:high", self.log())

    def test_host_literal_true_only(self):
        for content in ('[local]\n', '[local]\npi_anthropic = false\n',
                        '[local]\npi_anthropic = "true"\n', '[local]\npi_anthropic = 1\n',
                        '[local]\npi_anthropic = true\npi_anthropic = true\n',
                        '[local]\npi_anthropic: true\n', '[local\npi_anthropic = true\n'):
            with self.subTest(content=content):
                self.hosts(content + '[hub]\nmachine_id = "fixture-host"\n')
                result = self.spawn()
                self.assert_refused_before_admission(result, "pi_anthropic")
                self.assertIn("pi-sonnet55", result.stderr)
                self.assertIn("fixture-host", result.stderr)
        Path(self.env["WRK_HOSTS_CONFIG"]).unlink()
        self.assert_refused_before_admission(self.spawn(), "pi_anthropic")

    def test_ultra_refused(self):
        for effort in ("ultra", "off", "minimal"):
            with self.subTest(effort=effort):
                self.assert_refused_before_admission(self.spawn(effort=effort), effort)

    def test_gate_without_tomllib(self):
        # Python 3.9 compatibility: reject importing tomllib at the actual
        # interpreter boundary, delegating everything else to this suite's
        # >=3.11 interpreter. No real host config or agent is involved.
        shim = self.tmp / "bin/python3"
        shim.unlink()
        self.executable(shim, '#!/bin/bash\n' +
            f'exec "{sys.executable}" "{self.tmp / "without-tomllib.py"}" "$@"\n')
        (self.tmp / "without-tomllib.py").write_text('''import builtins, runpy, sys
original = builtins.__import__
def no_tomllib(name, *args, **kwargs):
    if name == "tomllib":
        raise ModuleNotFoundError("No module named tomllib (Python 3.9 fixture)")
    return original(name, *args, **kwargs)
builtins.__import__ = no_tomllib
args = sys.argv[1:]
if args[0] == "-c":
    sys.argv = ["-c"] + args[2:]
    exec(compile(args[1], "<string>", "exec"), {"__name__": "__main__"})
elif args[0] == "-":
    sys.argv = args
    exec(compile(sys.stdin.read(), "<stdin>", "exec"), {"__name__": "__main__"})
else:
    sys.argv = args
    runpy.run_path(args[0], run_name="__main__")
''')
        probe = subprocess.run([str(shim), "-c", "import tomllib"], env=self.env,
                               text=True, capture_output=True)
        self.assertNotEqual(probe.returncode, 0)
        admitted = self.spawn()
        self.assertEqual(admitted.returncode, 0, admitted.stdout + admitted.stderr)
        (self.tmp / "herdr.log").unlink()
        (self.tmp / "claims.log").unlink(missing_ok=True)
        self.test_host_literal_true_only()

    def test_builder_refused(self):
        for profile in PROFILES:
            with self.subTest(profile=profile):
                self.assert_refused_before_admission(self.spawn(profile=profile, role="builder"),
                                                     "worker/tester-only")

    def test_model_proof_failures_close_pane(self):
        for scenario in ("wrong-model", "wrong-thinking", "wrong-provider", "missing",
                         "echo", "stale", "no-provider"):
            with self.subTest(scenario=scenario):
                result = self.spawn(WRK_PI_SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("pi model not proven", result.stderr)
                self.assertIn("pane close w:p1", self.log())
                self.assertNotIn("OK pane=", result.stdout)

    def test_e6_marker_exact(self):
        self.assert_refused_before_admission(self.spawn(SCOPEFUEL_E6_ARM="pi-opus55@high"),
                                             "SCOPEFUEL_E6_ARM=pi-sonnet55@high")

    def test_policy_profiles(self):
        policy = json.loads((ROOT / "director/gate_policy.json").read_text())
        for profile, model in PROFILES.items():
            spec = policy["profiles"][profile]
            self.assertEqual((spec["family"], spec["launcher"], spec["model"]),
                             ("anthropic", "pi", model.split("/", 1)[1]))
            self.assertEqual((spec["roles"], spec["role_status"]), ([], "unknown"))

    def test_remote_execution_host_owns_opt_in(self):
        target = self.tmp / "target.toml"
        target.write_text('[local]\n[hub]\nmachine_id = "target-host"\n')
        self.hosts('[local]\npi_anthropic = true\n[hosts.target]\n' +
                   f'cwd_map = {{"{self.tmp}" = "{self.tmp}"}}\n')
        # SSH/SCP replay commands locally. Only the delegated wrk gets the
        # target's own config, as a real fresh SSH process would.
        ssh = self.tmp / "bin/ssh-fixture"
        self.executable(ssh, '#!/usr/bin/env python3\n' +
            'import os, subprocess, sys\n' +
            'command = sys.argv[-1]\nenv = dict(os.environ)\n' +
            'if "uptime; herdr agent list" in command:\n' +
            '    print(" 10:00 up 1 day, load average: 0.0, 0.0, 0.0")\n' +
            '    print(\'{"result":{"agents":[]}}\')\n    sys.exit(0)\n' +
            'if "wrk spawn" in command:\n' +
            f'    env["WRK_HOSTS_CONFIG"] = {str(target)!r}\n' +
            f'    env["WRK_FIXTURE_LOG"] = {str(self.tmp / "target.log")!r}\n' +
            'sys.exit(subprocess.call(["bash", "-c", command], env=env))\n')
        scp = self.tmp / "bin/scp-fixture"
        self.executable(scp, '#!/usr/bin/env python3\nimport shutil, sys\n' +
                        'shutil.copyfile(sys.argv[1], sys.argv[2].split(":",1)[1])\n')
        (self.tmp / "bin/wrk").symlink_to(self.wrk)
        command = [str(self.wrk), "spawn", "--host", "target", "-c", str(self.tmp),
                   "-m", "pi-sonnet55", "--effort", "high", "-p", str(self.brief),
                   "-w", "w", "-l", "pi-remote", "--task", "2080", "--task-hk-bypass", "--t", "T1"]
        env = dict(self.env, WRK_SSH_BIN=str(ssh), WRK_SCP_BIN=str(scp),
                   SCOPEFUEL_E6_ARM="pi-sonnet55@high")
        refused = subprocess.run(command, env=env, text=True, capture_output=True, timeout=40)
        self.assertNotEqual(refused.returncode, 0, refused.stdout + refused.stderr)
        self.assertIn("pi-sonnet55 refused on host target-host", refused.stderr)
        self.assertIn("pi_anthropic", refused.stderr)
        self.assertNotIn("tab create", self.log("target.log"))
        self.assertFalse((self.tmp / "claims.log").exists())
        # Sender without opt-in may delegate to a target that has opted in.
        target.write_text('[local]\npi_anthropic = true\n')
        self.hosts(f'[hosts.target]\ncwd_map = {{"{self.tmp}" = "{self.tmp}"}}\n')
        allowed = subprocess.run(command, env=env, text=True, capture_output=True, timeout=40)
        self.assertEqual(allowed.returncode, 0, allowed.stdout + allowed.stderr)
        self.assertIn("OK pane=", allowed.stdout)

    def test_anthropic_api_quota_record(self):
        try:
            result = self.spawn(ARBITER_BIN=str(ROOT / "bin/arbiter"),
                                WRK_COMPLETION_INTERVAL_S="3600")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            events = Path(self.env["ARBITER_INBOX_ROOT"]) / "pi-fixture/events"
            records = list(events.glob("*-quota_pool.record.json"))
            self.assertEqual(len(records), 1, result.stdout + result.stderr)
            payload = json.loads(records[0].read_text())["payload"]
            self.assertEqual((payload["profile"], payload["launch_profile"], payload["pool"]),
                             ("pi-sonnet55", "pi-sonnet55@high", "anthropic-api"))
        finally:
            pidfile = Path(self.env["ARBITER_INBOX_ROOT"]) / "pi-fixture/completion-sentinel.pid"
            if pidfile.exists():
                pid = int(pidfile.read_text().splitlines()[0])
                check = subprocess.run(["ps", "-p", str(pid), "-o", "args="],
                                       capture_output=True, text=True)
                if "sentinel pi-fixture " in check.stdout and str(ROOT / "bin/wrk") in check.stdout:
                    try:
                        group = os.getpgid(pid)
                        if group in self.groups:
                            os.killpg(group, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            # This test owns every writer under its root. Verify exact pids
            # with the shared library before TemporaryDirectory removes it.
            stopped = subprocess.run(
                ["bash", "-c", '. "$1"; TW_TMP="$2"; tmp_writers_stop; rc=$?; printf "leftovers=%s\\n" "$TW_LEFTOVER_PIDS"; exit "$rc"', "cleanup",
                 str(ROOT / "tests/lib/tmp-writers.sh"), str(self.tmp)],
                env=self.env, capture_output=True, text=True, timeout=30)
            if stopped.returncode:
                self.keep_tmp = True
                self.temp._finalizer.detach()  # preserve evidence for live writers
            self.assertEqual(stopped.returncode, 0, stopped.stdout + stopped.stderr)


class PiMutantTests(unittest.TestCase):
    def test_call_site_mutants_are_killed_by_assertions(self):
        source = (ROOT / "bin/wrk").read_text()
        mutants = {
            "host": ('  pi_host_precheck\n', '  : # missing host guard\n',
                     "test_host_literal_true_only"),
            "thinking": ('pi) ARGS=(--no-mcp --model "$PROFILE_MODEL:$PI_THINKING")',
                         'pi) ARGS=(--no-mcp --model "$PROFILE_MODEL:low")',
                         "test_argv_gate_mapping_and_no_mcp"),
            "proof": ('if [[ "$PROFILE_KIND" == pi ]] && ! pi_model_proven; then',
                      'if false; then', "test_model_proof_failures_close_pane"),
            "builder": ('die "--role builder rejects \'$MODEL\': pi seats are worker/tester-only until reps exist (hk 2080)"',
                        ': # missing role guard', "test_builder_refused"),
            "mcp": ('pi) ARGS=(--no-mcp --model "$PROFILE_MODEL:$PI_THINKING")',
                    'pi) ARGS=(--model "$PROFILE_MODEL:$PI_THINKING")',
                    "test_argv_gate_mapping_and_no_mcp"),
            "truthy": ('true) LOCAL_PI_ANTHROPIC=1 ;;',
                       'true|false|1|\\\"true\\\") LOCAL_PI_ANTHROPIC=1 ;;',
                       "test_host_literal_true_only"),
        }
        for name, (old, new, method) in mutants.items():
            with self.subTest(mutant=name):
                self.assertEqual(source.count(old), 1, name)
                case = PiSpawnTests(method)
                case.setUp()
                try:
                    mutant = case.tmp / "wrk-mutant"
                    mutated = source.replace(old, new, 1)
                    if name == "host":
                        # Disable both execution-local entry points; an
                        # initiator with --host target still has no opt-in.
                        mutated = mutated.replace('pi_host_precheck "$router_profile"', ':')
                    case.executable(mutant, mutated)
                    case.wrk = mutant
                    # Direct method invocation: only AssertionError counts,
                    # never an exception or an unsuccessful harness setup.
                    with self.assertRaises(AssertionError):
                        getattr(case, method)()
                finally:
                    case.doCleanups()


if __name__ == "__main__":
    unittest.main(verbosity=2)
