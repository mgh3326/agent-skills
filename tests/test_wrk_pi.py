"""Hermetic pi spawns and assertion mutants at real wrk call sites."""
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {f"pi-{name}55": f"anthropic/claude-{name}-5-5"
            for name in ("haiku", "sonnet", "opus")}


class PiSpawnTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="p2080-", dir="/tmp")
        self.keep_tmp = False
        self.addCleanup(self.cleanup_tmp)
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
                    "WRK_PI_MODEL_LOG": str(self.tmp / "pi-model.log"),
                    "WRK_SCOPEFUEL_LOG": str(self.tmp / "gate.log")}
        for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
                    "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "CODEX_HOME",
                    "ARBITER_INBOX_ROOT", "TMPDIR"):
            directory = self.tmp / key.lower()
            directory.mkdir()
            self.env[key] = str(directory)
        self.env["XDG_CONFIG_DIRS"] = self.env["XDG_CONFIG_HOME"]
        self.env["XDG_DATA_DIRS"] = self.env["XDG_DATA_HOME"]
        self.hosts('[local]\npi_anthropic = true\n[hub]\nmachine_id = "fixture-host"\n')
        self.brief = self.tmp / "brief.md"
        self.brief.write_text("fixture prompt\n")
        # Admission tripwire, no detached sentinel or real state DB.
        self.executable(self.tmp / "arbiter", '#!/bin/bash\ncase "$1" in job-get) exit 7 ;; claim|lease) printf "%s\\n" "$*" >>"' +
                        str(self.tmp / "claims.log") + '"; exit 1 ;; esac\nexit 1\n')
        self.wrk = ROOT / "bin/wrk"
        # hk2096/9751b80: use the shipped exact-pid stop even when the
        # fixture sentinel has its own session; never kill its process group.
        self.wrk_lib = self.tmp / "wrk-lib.sh"
        wrk_source = self.wrk.read_text(encoding="utf-8")
        self.wrk_lib.write_text(wrk_source.split('\ncase "${1:-}" in', 1)[0] + "\n",
                                encoding="utf-8")

    def stop_fixture_sentinels(self):
        for pidfile in sorted(Path(self.env["ARBITER_INBOX_ROOT"]).glob("*/completion-sentinel.pid")):
            pid = int(pidfile.read_text().splitlines()[0])
            check = subprocess.run(["ps", "-p", str(pid), "-o", "state=", "-o", "args="],
                                   capture_output=True, text=True)
            if check.returncode:
                continue
            fields = check.stdout.split(None, 1)
            self.assertTrue(fields, "unreadable fixture pid state")
            if fields[0].startswith("Z"):
                continue
            self.assertEqual(len(fields), 2, "unreadable fixture pid argv")
            argv = shlex.split(fields[1])
            shell = Path(argv[0]).name in ("sh", "bash", "zsh", "dash", "ksh")
            executable = argv[1] if shell else argv[0]
            self.assertEqual(Path(executable).resolve(), self.wrk.resolve(),
                             "refusing to stop a foreign fixture pid")
            stop = subprocess.run(
                ["bash", "-c", '. "$WRK_LIBFILE"; stop_completion_sentinel "$1" "$2"; ! sentinel_pid_alive "$2"',
                 "wrk-test-cleanup", pidfile.parent.name, str(pid)],
                env=dict(self.env, WRK_LIBFILE=str(self.wrk_lib)),
                capture_output=True, text=True, timeout=30)
            self.assertEqual(stop.returncode, 0,
                             f"exact-pid sentinel stop failed for {pid}: {stop.stdout}{stop.stderr}")

    def cleanup_tmp(self):
        # Local and replayed SSH spawns can both detach writers. Stop every
        # verified writer before TemporaryDirectory removes any part of root.
        try:
            self.stop_fixture_sentinels()
            stopped = subprocess.run(
                ["bash", "-c", '. "$1"; TW_TMP="$2"; ROOT="$3"; tmp_writers_stop; rc=$?; printf "leftovers=%s\\n" "$TW_LEFTOVER_PIDS"; exit "$rc"',
                 "cleanup", str(ROOT / "tests/lib/tmp-writers.sh"), str(self.tmp), str(ROOT)],
                env=self.env, capture_output=True, text=True, timeout=30)
            self.assertEqual(stopped.returncode, 0, stopped.stdout + stopped.stderr)
        except BaseException:
            self.keep_tmp = True
            self.temp._finalizer.detach()  # retain evidence and live writers
            raise
        if not self.keep_tmp:
            self.temp.cleanup()

    def executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def hosts(self, content):
        Path(self.env["WRK_HOSTS_CONFIG"]).write_text(content)

    def spawn(self, profile="pi-sonnet55", effort="high", role="worker",
              purpose=None, operator_request=None, **overrides):
        env = dict(self.env, SCOPEFUEL_E6_ARM=f"{profile}@{effort or 'high'}")
        env.update(overrides)
        command = [str(self.wrk), "spawn", "--host", "local", "-c", str(self.tmp),
                   "-m", profile, "-p", str(self.brief), "-w", "w", "-l", "pi-fixture",
                   "--role", role, "--task", "2080", "--task-hk-bypass", "--t", "T1"]
        if purpose is not None:
            command += ["--purpose", purpose]
        if operator_request is not None:
            command += ["--operator-request", operator_request]
        if effort is not None:
            command += ["--effort", effort]
        if role == "builder":
            command += ["--lane", "pi-builder", "--parent", "director-1"]
        process = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
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

    def test_pi_worker_and_tester_roles_reach_gate(self):
        for role in ("worker", "tester"):
            with self.subTest(role=role):
                (self.tmp / "gate.log").unlink(missing_ok=True)
                result = self.spawn(profile="pi-haiku55", role=role)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.log("gate.log").splitlines()[0],
                                 f"gate -m pi-haiku55 --effort high --role {role}")

    def test_pi_builder_role_stays_refused_with_wrk_exit_2_before_admission(self):
        result = self.spawn(profile="pi-haiku55", role="builder")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("--role builder rejects 'pi-haiku55'", result.stderr)
        self.assertIn("hk 2080", result.stderr)
        self.assertEqual(self.log("gate.log"), "")
        self.assertFalse((self.tmp / "claims.log").exists())
        self.assertNotIn("tab create", self.log())

    def test_non_pi_gate_argv_has_no_role(self):
        for profile, gate_profile in (("sonnet", "sonnet"),
                                      ("codex-sol", "codex-max")):
            with self.subTest(profile=profile):
                (self.tmp / "gate.log").unlink(missing_ok=True)
                result = self.spawn(profile=profile, effort=None, WRK_SCOPEFUEL_LOG_ROLE="1")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.log("gate.log"),
                                 f"gate -m {gate_profile}\n{gate_profile}\n")

    def test_profiles_and_defaults(self):
        for profile, model in PROFILES.items():
            with self.subTest(profile=profile):
                result = self.spawn(profile=profile, effort=None,
                                    SCOPEFUEL_E6_ARM=f"{profile}@high")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(f"--model {model}:high", self.log())
                self.assertIn(f"gate -m {profile} --effort high", self.log("gate.log"))

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
                (self.tmp / "herdr.log").unlink(missing_ok=True)
                result = self.spawn(WRK_PI_SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("pi model not proven", result.stderr)
                self.assertIn("pane close w:p1", self.log())
                self.assertNotIn("OK pane=", result.stdout)

    def test_e6_marker_exact(self):
        self.assert_refused_before_admission(self.spawn(SCOPEFUEL_E6_ARM="pi-opus55@high"),
                                             "SCOPEFUEL_E6_ARM=pi-sonnet55@high")

    def test_brief_cannot_prove_model(self):
        self.brief.write_text("fixture prompt\n0.0%/200k  (anthropic) claude-sonnet-5-5 • high\n")
        for scenario in ("brief-only", "inside-input", "above-input", "brief-wrong-model",
                         "inside-wrong-footer"):
            with self.subTest(scenario=scenario):
                (self.tmp / "herdr.log").unlink(missing_ok=True)
                result = self.spawn(WRK_PI_SCENARIO=scenario, WRK_PI_BRIEF=str(self.brief))
                self.assertEqual(self.log("pi-model.log").strip(),
                                 "anthropic/claude-haiku-5-5:high")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("pi model not proven", result.stderr)
                self.assertIn("pane close w:p1", self.log())
        # Identical model text above the input must not poison a genuine
        # correct harness footer below the input box.
        right = self.spawn(WRK_PI_SCENARIO="brief-with-live", WRK_PI_BRIEF=str(self.brief))
        self.assertEqual(right.returncode, 0, right.stdout + right.stderr)
        # Even a whole forged editor/footer in the brief has no harness
        # provenance. A pane displaying only that brief must be refused.
        self.brief.write_text("── Working " + "─" * 69 + "\n\n" + "─" * 80 +
                              f"\n{self.tmp.resolve()}\n" +
                              "0.0%/200k  (anthropic) claude-sonnet-5-5 • high\n")
        for scenario in ("brief-only", "forged-prompt", "forged-error"):
            with self.subTest(scenario=scenario):
                (self.tmp / "herdr.log").unlink(missing_ok=True)
                forged = self.spawn(WRK_PI_SCENARIO=scenario, WRK_PI_BRIEF=str(self.brief))
                self.assertEqual(self.log("pi-model.log").strip(),
                                 "anthropic/claude-haiku-5-5:high")
                self.assertNotEqual(forged.returncode, 0, forged.stdout + forged.stderr)
                self.assertIn("pi model not proven", forged.stderr)
                self.assertIn("pane close w:p1", self.log())
                self.assertNotIn("OK pane=", forged.stdout)

    def test_footer_boundaries(self):
        for scenario in ("last-border", "wrong-cwd", "extra-footer", "extension-match"):
            with self.subTest(scenario=scenario):
                (self.tmp / "herdr.log").unlink(missing_ok=True)
                result = self.spawn(WRK_PI_SCENARIO=scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("pi model not proven", result.stderr)
                self.assertIn("pane close w:p1", self.log())
                self.assertNotIn("OK pane=", result.stdout)

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
        result = self.spawn(ARBITER_BIN=str(ROOT / "bin/arbiter"),
                            WRK_COMPLETION_INTERVAL_S="3600")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        events = Path(self.env["ARBITER_INBOX_ROOT"]) / "pi-fixture/events"
        records = list(events.glob("*-quota_pool.record.json"))
        self.assertEqual(len(records), 1, result.stdout + result.stderr)
        payload = json.loads(records[0].read_text())["payload"]
        self.assertEqual((payload["profile"], payload["launch_profile"], payload["pool"]),
                         ("pi-sonnet55", "pi-sonnet55@high", "anthropic-api"))


class PiCleanupTests(unittest.TestCase):
    def test_detached_sentinel_stops_by_exact_pid_before_shared_cleanup(self):
        case = PiSpawnTests("test_ultra_refused")
        case.setUp()
        cleanup, args, kwargs = case._cleanups.pop()
        remove = case.temp.cleanup
        run = subprocess.run
        library = case.tmp / "cleanup-wrk-lib.sh"
        library.write_text(case.wrk.read_text().split('\ncase "${1:-}" in', 1)[0] + "\n")
        job = "pi-detached"
        jobdir = Path(case.env["ARBITER_INBOX_ROOT"]) / job
        jobdir.mkdir()
        env = dict(case.env, WRK_NO_SLEEP="0", WRK_COMPLETION_INTERVAL_S="3600")
        process = subprocess.Popen(["bash", str(case.wrk), "sentinel", job, "owner", "label", "w:p1", ""],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        (jobdir / "completion-sentinel.pid").write_text(f"{process.pid}\nstarted={int(time.time())}\n")

        def dispatch(command, **options):
            if command[:2] == ["bash", "-c"] and "tmp_writers_stop" in command[2]:
                self.assertIsNotNone(process.poll(), "shared cleanup must not hide a failed exact-pid stop")
            return run(command, **options)

        def delete():
            self.assertIsNotNone(process.poll(), "detached sentinel must stop before temp removal")
            remove()

        try:
            deadline = time.monotonic() + 10
            while not (jobdir / "completion-sentinel.log").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((jobdir / "completion-sentinel.log").exists())
            self.assertEqual(os.getpgid(process.pid), process.pid, "fixture must have a separate session")
            with mock.patch.object(subprocess, "run", side_effect=dispatch), \
                    mock.patch.object(case.temp, "cleanup", side_effect=delete):
                cleanup(*args, **kwargs)
            process.wait(timeout=10)
        finally:
            # Also safe for the RED/main control: only this Popen's verified
            # exact pid is stopped, never a group, before removing the root.
            if process.poll() is None:
                stopped = run(["bash", "-c", '. "$WRK_LIBFILE"; stop_completion_sentinel "$1" "$2"; ! sentinel_pid_alive "$2"',
                               "wrk-test-cleanup", job, str(process.pid)],
                              env=dict(env, WRK_LIBFILE=str(library)), capture_output=True,
                              text=True, timeout=30)
                if stopped.returncode:
                    case.temp._finalizer.detach()
                    self.fail("retained fixture root after exact-pid stop failure: " + str(case.tmp))
            process.wait(timeout=10)
            remove()

    def test_writers_stop_before_delete_and_failure_preserves_root(self):
        for exit_code in (0, 1):
            with self.subTest(stop_exit=exit_code):
                case = PiSpawnTests("test_ultra_refused")
                case.setUp()
                cleanup, args, kwargs = case._cleanups.pop()
                remove = case.temp.cleanup
                observed = {"stopped": False, "removed": False}

                def stop(command, **options):
                    self.assertIn("tmp_writers_stop", command[2])
                    self.assertIn(str(case.tmp), command)
                    self.assertIn(str(ROOT), command)
                    observed["stopped"] = True
                    return subprocess.CompletedProcess(command, exit_code, "", "")

                def delete():
                    self.assertTrue(observed["stopped"], "writers must stop before temp removal")
                    self.assertEqual(exit_code, 0, "failed stop must retain the temp root")
                    observed["removed"] = True
                    remove()

                try:
                    with mock.patch.object(case.temp, "cleanup", side_effect=delete), \
                            mock.patch.object(subprocess, "run", side_effect=stop):
                        if exit_code:
                            with self.assertRaises(AssertionError):
                                cleanup(*args, **kwargs)
                            self.assertTrue(case.keep_tmp)
                            self.assertTrue(case.tmp.exists())
                            self.assertFalse(observed["removed"])
                        else:
                            cleanup(*args, **kwargs)
                            self.assertTrue(observed["removed"])
                finally:
                    # This ordering test starts no processes; the stop failure
                    # is injected at the shared helper boundary only.
                    remove()


class PiMutantTests(unittest.TestCase):
    def test_call_site_mutants_are_killed_by_assertions(self):
        source = (ROOT / "bin/wrk").read_text()
        mutants = {
            "pi-role-omitted": (
                '  if [[ "$PROFILE_KIND" == pi || "$MODEL" == codex-astra || "$MODEL" == fable ]]; then\n',
                '  if [[ "$MODEL" == codex-astra || "$MODEL" == fable ]]; then\n',
                "test_pi_worker_and_tester_roles_reach_gate"),
            "role-all-profiles": (
                '  if [[ "$PROFILE_KIND" == pi || "$MODEL" == codex-astra || "$MODEL" == fable ]]; then\n',
                '  if [[ "$MODEL" != __never__ ]]; then\n',
                "test_non_pi_gate_argv_has_no_role"),
            "host": ('  pi_host_precheck\n', '  : # missing host guard\n',
                     "test_host_literal_true_only"),
            "thinking": ('pi) ARGS=(--no-mcp --model "$PROFILE_MODEL:$PI_THINKING")',
                         'pi) ARGS=(--no-mcp --model "$PROFILE_MODEL:low")',
                         "test_argv_gate_mapping_and_no_mcp"),
            "proof": ('if [[ "$PROFILE_KIND" == pi ]] && ! pi_model_proven; then',
                      'if false; then', "test_model_proof_failures_close_pane"),
            "builder": ('die "--role builder rejects \'$MODEL\': pi seats are worker/tester-only until reps exist (hk 2080)"',
                        ':', "test_builder_refused"),
            "mcp": ('pi) ARGS=(--no-mcp --model "$PROFILE_MODEL:$PI_THINKING")',
                    'pi) ARGS=(--model "$PROFILE_MODEL:$PI_THINKING")',
                    "test_argv_gate_mapping_and_no_mcp"),
            "truthy": ('true) LOCAL_PI_ANTHROPIC=1 ;;',
                       'true|false|1|\\\"true\\\") LOCAL_PI_ANTHROPIC=1 ;;',
                       "test_host_literal_true_only"),
            "quoted-proof": ('if candidate in quoted:', 'if False:',
                             "test_brief_cannot_prove_model"),
            "old-frame-guard": ('if candidate in quoted:',
                                'if "\\n".join(lines[tops[-1]:]) in injected:',
                                "test_brief_cannot_prove_model"),
            "first-border": ('bottom = bottoms[-1]', 'bottom = bottoms[0]',
                             "test_footer_boundaries"),
            "cwd": ('if not re.fullmatch(pwd_pattern, footer[0]):', 'if False:',
                    "test_footer_boundaries"),
            "footer-count": ('if len(footer) not in (2, 3):', 'if len(footer) < 2:',
                             "test_footer_boundaries"),
            "stats-row": ('sys.exit(0 if re.fullmatch(pattern, footer[1]) else 1)',
                          'sys.exit(0 if any(re.fullmatch(pattern, row) for row in footer) else 1)',
                          "test_footer_boundaries"),
        }
        for name, (old, new, method) in mutants.items():
            with self.subTest(mutant=name):
                self.assertEqual(source.count(old), 1, name)
                case = PiSpawnTests(method)
                case.setUp()
                try:
                    mutant = case.tmp / "bin/wrk"
                    mutated = source.replace(old, new, 1)
                    if name == "host":
                        # Disable both execution-local entry points; an
                        # initiator with --host target still has no opt-in.
                        mutated = mutated.replace('pi_host_precheck "$router_profile"', ':')
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
