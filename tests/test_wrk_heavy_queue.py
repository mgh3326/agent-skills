"""hk 1407: real heavy entry-point tests, using only file-controlled fixtures."""

import base64
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
WRK = Path(os.environ.get("WRK_QUEUE_TEST_BIN", ROOT / "bin/wrk"))
POLL = threading.Event()


class HeavyQueue(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hq-", dir="/tmp")
        self.base = Path(self.tmp.name)
        self.procs = []
        self.files = []
        self.lock = self.base / "lock"
        self.waiters = Path(str(self.lock) + ".waiters")
        self.positions = Path(str(self.lock) + ".positions")
        self.waiters.mkdir()
        self.positions.mkdir()
        self.env = dict(os.environ)
        for name in ("ARBITER_JOB", "HK_TASK_ID", "WRK_HEAVY_HELD",
                     "WRK_HEAVY_HELD_FD", "WRK_HEAVY_QUEUE_KEY"):
            self.env.pop(name, None)
        for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
                     "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "CODEX_HOME",
                     "ARBITER_INBOX_ROOT", "TMPDIR"):
            path = self.base / name.lower()
            path.mkdir()
            self.env[name] = str(path)
        self.env.update(WRK_HEAVY_LOCK=str(self.lock),
                        WRK_HEAVY_LOG=str(self.base / "heavy.log"),
                        WRK_HOSTS_CONFIG=str(self.base / "hosts.toml"),
                        WRK_HEAVY_MAX="1", WRK_HEAVY_CLASS="lane",
                        WRK_HEAVY_CI_DEFER_MAX="1800", WRK_HEAVY_WAIT_CAP="15",
                        WRK_HEAVY_REQUEUE_GRACE="600")
        (self.base / "hosts.toml").write_text("[local]\nheavy_load_wait = false\n")
        self.fixture = self.base / "fixture.py"
        self.fixture.write_text(
            "import pathlib, sys, threading, time\n"
            "base, name = pathlib.Path(sys.argv[1]), sys.argv[2]\n"
            "with (base / 'order').open('a') as f: f.write(name + '\\n')\n"
            "(base / (name + '.start')).touch()\n"
            "deadline = time.monotonic() + 30\n"
            "while not (base / (name + '.release')).exists():\n"
            "    if time.monotonic() > deadline: raise SystemExit(99)\n"
            "    threading.Event().wait(.02)\n")

    def tearDown(self):
        for path in self.files:
            path.touch()
        # A failed assertion cannot leave a holder behind: release all fixture
        # commands, then wait for their own per-run caps. No pattern signals.
        for proc, out in self.procs:
            try:
                proc.wait(timeout=35)
            except subprocess.TimeoutExpired:
                # Signal only the Popen child after a fresh ps identity check.
                check = subprocess.run(["ps", "-p", str(proc.pid), "-o", "ppid="],
                                       capture_output=True, text=True, check=False)
                if proc.poll() is None and check.stdout.strip() == str(os.getpid()):
                    proc.terminate()
                proc.wait(timeout=5)
            out.close()
        self.tmp.cleanup()

    def until(self, predicate, message, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            POLL.wait(.02)
        self.fail(message)

    def run_wrk(self, *args, binary=WRK, **overrides):
        return subprocess.run([str(binary), "heavy", *args],
                              env=dict(self.env, **overrides), capture_output=True,
                              text=True, timeout=15, check=False)

    def spawn(self, name, key=None, binary=WRK, **overrides):
        release = self.base / (name + ".release")
        self.files.append(release)
        args = [str(binary), "heavy"]
        if key is not None:
            args += ["--queue-key", key]
        args += ["--", sys.executable, str(self.fixture), str(self.base), name]
        out = (self.base / (name + ".out")).open("w+")
        proc = subprocess.Popen(args, env=dict(self.env, **overrides), stdout=out,
                                stderr=subprocess.STDOUT)
        self.procs.append((proc, out))
        return proc

    def started(self, name):
        return (self.base / (name + ".start")).exists()

    def start(self, name, **kwargs):
        proc = self.spawn(name, **kwargs)
        self.until(lambda: self.started(name), f"{name} never acquired a slot")
        return proc

    def release(self, name):
        (self.base / (name + ".release")).touch()

    def queued(self, name):
        def record():
            for path in self.waiters.iterdir():
                if not path.name.startswith(".") and path.is_file():
                    info = path.read_text()
                    if info.endswith(" " + name):
                        return info
            return None
        self.until(record, f"{name} never published a waiter record")
        return record()

    def ticket(self, info):
        match = re.search(r"(?:^| )ticket=(\d+):(\d+)(?: |$)", info)
        self.assertIsNotNone(match, "waiter record has no enqueue ticket")
        return tuple(map(int, match.groups()))

    def position_path(self, key):
        return self.positions / ("key-" + key.encode("ascii").hex() + ".json")

    def position_records(self):
        return [json.loads(p.read_text()) for p in self.positions.iterdir()
                if not p.name.startswith(".") and p.is_file() and not p.is_symlink()]

    def test_fifo_three_lane_waiters(self):
        holder = self.start("holder")
        waiters, tickets = [], []
        for name in ("first", "second", "third"):
            waiters.append(self.spawn(name))
            tickets.append(self.ticket(self.queued(name)))
        self.assertEqual(tickets, sorted(set(tickets)))
        self.release("holder")
        self.assertEqual(holder.wait(timeout=5), 0)
        for index, name in enumerate(("first", "second", "third")):
            self.until(lambda: self.started(name), f"FIFO did not admit {name}")
            self.assertEqual((self.base / "order").read_text().splitlines(),
                             ["holder", "first", "second", "third"][:index + 2])
            self.release(name)
            self.assertEqual(waiters[index].wait(timeout=5), 0)

    def plant_lane(self, pid, ticket="1:1", limit=1):
        (self.waiters / str(pid)).write_text(
            f"pid={pid} class=lane limit={limit} ticket={ticket} since=x job=- cmd=fixture")

    def plant_start_lane(self, pid, start, ticket="1:1", limit=1):
        (self.waiters / str(pid)).write_text(
            f"pid={pid} class=lane limit={limit} ticket={ticket} start={start} since=x job=- cmd=fixture")

    def legacy_reader_fields(self, text):
        tokens = text.split(None, 3)[:3]
        pid, cls, limit = -1, "lane", None
        if tokens and tokens[0].startswith("pid="):
            try:
                pid = int(tokens[0][4:])
            except ValueError:
                pass
        for token in tokens[1:]:
            if token.startswith("class=") and token[6:] in ("ci", "lane"):
                cls = token[6:]
            elif token.startswith("limit="):
                try:
                    limit = int(token[6:])
                except ValueError:
                    pass
        fields = text.split(None, 4)
        ticket = None
        if len(fields) >= 4:
            match = re.fullmatch(r"ticket=([0-9]{1,20}):([0-9]{1,20})", fields[3])
            if match:
                ticket = tuple(map(int, match.groups()))
        return pid, cls, limit, ticket

    def test_new_waiter_record_has_a_fixed_head_start_identity(self):
        self.start("identity-holder")
        self.spawn("identity-waiter")
        info = self.queued("identity-waiter")
        self.assertRegex(info, r"^pid=\d+ class=lane limit=1 ticket=\d+:\d+ start=[A-Za-z0-9:_-]+ ")

    def test_macos_identity_uses_exact_ps_lstart_text(self):
        source = WRK.read_text()
        identity_body = source.split("def process_start_identity(pid):", 1)[1].split(
            "owner_identity_unknown_logged = False", 1)[0]
        self.assertIn('["/bin/ps", "-o", "lstart=", "-p", str(pid)]', identity_body)
        self.assertNotIn("ctypes", identity_body)
        self.assertNotIn("proc_pidinfo", identity_body)
        lstart = "  Mon Oct 26 10:11:12 2026"
        encoded = base64.urlsafe_b64encode(lstart.encode("utf-8")).decode("ascii").rstrip("=")
        anchor = "def process_start_identity(pid):\n"
        injection = (
            "_identity_test_real_run = subprocess.run\n"
            "sys.platform = 'darwin'\n"
            "def _identity_test_ps(argv, **kwargs):\n"
            "    if argv[:4] == ['/bin/ps', '-o', 'lstart=', '-p']:\n"
            "        assert kwargs.get('env') == {'LC_ALL': 'C', 'TZ': 'UTC'}\n"
            f"        return type('PSResult', (), {{'returncode': 0, 'stdout': {lstart + chr(10)!r}}})()\n"
            "    return _identity_test_real_run(argv, **kwargs)\n"
            "subprocess.run = _identity_test_ps\n" + anchor)
        binary = self.instrument("mac-identity-wrk", anchor, injection)
        self.start("mac-identity-holder", binary=binary)
        self.spawn("mac-identity-waiter", binary=binary)
        info = self.queued("mac-identity-waiter")
        self.assertIn("start=darwin:" + encoded, info)

    def test_legacy_reader_preserves_fields_on_new_record(self):
        self.start("compat-holder")
        self.spawn("compat-waiter")
        info = self.queued("compat-waiter")
        fields = info.split()
        expected = (int(fields[0][4:]), fields[1][6:], int(fields[2][6:]),
                    tuple(map(int, fields[3][7:].split(":"))))
        self.assertRegex(fields[4], r"start=[A-Za-z0-9:_-]+")
        self.assertEqual(self.legacy_reader_fields(info), expected)

    def test_start_after_pid_mutant_breaks_legacy_reader(self):
        self.start("compat-mutant-holder")
        self.spawn("compat-mutant-waiter")
        info = self.queued("compat-mutant-waiter")
        fields = info.split()
        expected = self.legacy_reader_fields(info)
        mutant = " ".join(fields[:1] + [fields[4]] + fields[1:4] + fields[5:])
        self.assertNotEqual(self.legacy_reader_fields(mutant), expected,
                            "the start-after-pid mutant preserved the base reader fields")

    def test_pid_reuse_mismatch_stops_reserving_and_status_retires_once(self):
        pid = os.getpid()
        record = self.waiters / str(pid)
        self.plant_start_lane(pid, "0" * 64)
        run = self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(run.returncode, 0,
                         "pid-reuse mismatch reserves nothing: " + run.stderr)
        status = self.run_wrk("status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertFalse(record.exists(), "status retained a record whose pid has a different start identity")
        rows = [json.loads(line) for line in (self.base / "heavy.log").read_text().splitlines()]
        retired = [row for row in rows if row.get("kind") == "waiter_retired"
                   and row.get("record") == str(pid)]
        self.assertEqual(len(retired), 1, rows)
        self.assertEqual(retired[0]["reason"], "start-mismatch")

    def test_eperm_identity_states(self):
        anchor = 'if args[0] == "status":\n'
        cases = (("matching", "f" * 64, 75),
                 ("mismatched", "e" * 64, 0),
                 ("unreadable", None, 75))
        for case, observed_start, expected_rc in cases:
            with self.subTest(case=case):
                pid = os.getpid() + 100000 + len(case)
                record = self.waiters / str(pid)
                self.plant_start_lane(pid, "f" * 64)
                start_expr = "None" if observed_start is None else repr(observed_start)
                injection = (
                    f"_eperm_pid = {pid}\n"
                    "_real_kill = os.kill\n"
                    "_real_start_identity = process_start_identity\n"
                    "def _kill_with_eperm(target, sig):\n"
                    "    if target == _eperm_pid: raise PermissionError(1, 'permission denied')\n"
                    "    return _real_kill(target, sig)\n"
                    "def _stub_start_identity(target):\n"
                    f"    if target == _eperm_pid: return {start_expr}\n"
                    "    return _real_start_identity(target)\n"
                    "os.kill = _kill_with_eperm\n"
                    "process_start_identity = _stub_start_identity\n")
                binary = self.instrument("eperm-" + case + "-wrk", anchor,
                                         injection + anchor)
                result = self.run_wrk("--", "true", binary=binary,
                                      WRK_HEAVY_WAIT_CAP=".6")
                self.assertEqual(result.returncode, expected_rc,
                                 f"EPERM {case} identity state had wrong result: {result.stderr}")
                if case == "mismatched":
                    status = self.run_wrk("status", binary=binary)
                    self.assertFalse(record.exists(), "EPERM with a different start was retained")
                    rows = [json.loads(line) for line in
                            (self.base / "heavy.log").read_text().splitlines()]
                    retired = [row for row in rows if row.get("kind") == "waiter_retired"
                               and row.get("record") == str(pid)]
                    self.assertEqual(len(retired), 1, status.stdout + status.stderr)
                    self.assertEqual(retired[0]["reason"], "start-mismatch")
                elif case == "unreadable":
                    self.assertTrue(record.exists(), "unreadable EPERM identity was retired")
                    rows = [json.loads(line) for line in
                            (self.base / "heavy.log").read_text().splitlines()]
                    unknown = [row for row in rows if row.get("kind") == "owner_identity_unknown"]
                    self.assertEqual(len(unknown), 1, rows)

    def test_unknown_start_identity_keeps_record_and_logs_once(self):
        pid = os.getpid()
        record = self.waiters / str(pid)
        self.plant_start_lane(pid, "f" * 64)
        anchor = 'if args[0] == "status":\n'
        binary = self.instrument("unknown-start-wrk", anchor,
            "process_start_identity = lambda target: None\n" + anchor)
        result = self.run_wrk("--", "true", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(result.returncode, 75, "unknown owner identity stopped reserving")
        self.assertTrue(record.exists(), "unknown owner identity was retired")
        rows = [json.loads(line) for line in (self.base / "heavy.log").read_text().splitlines()]
        unknown = [row for row in rows if row.get("kind") == "owner_identity_unknown"]
        self.assertEqual(len(unknown), 1, rows)
        status = self.run_wrk("status", binary=binary)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertTrue(record.exists(), "status retired an owner with unknown identity")
        rows = [json.loads(line) for line in (self.base / "heavy.log").read_text().splitlines()]
        unknown = [row for row in rows if row.get("kind") == "owner_identity_unknown"]
        self.assertEqual(len(unknown), 2, rows)

    def test_unreadable_writer_identity_is_unknown_and_not_retired(self):
        self.start("unknown-writer-holder")
        anchor = 'owner_start = process_start_identity(os.getpid()) or "unknown"\n'
        binary = self.instrument("unknown-writer-wrk", anchor,
                                 "process_start_identity = lambda pid: None\n" + anchor)
        self.spawn("unknown-writer-waiter", binary=binary)
        info = self.queued("unknown-writer-waiter")
        fields = info.split()
        self.assertEqual(fields[4], "start=unknown")
        record = self.waiters / fields[0][4:]
        status = self.run_wrk("status", binary=binary)
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertTrue(record.exists(), "unreadable writer identity was retired")
        rows = [json.loads(line) for line in (self.base / "heavy.log").read_text().splitlines()]
        unknown = [row for row in rows if row.get("kind") == "owner_identity_unknown"
                   and row.get("record") == record.name]
        self.assertEqual(len(unknown), 1, rows)

    def test_start_token_in_command_cannot_forge_head_identity(self):
        pid = os.getpid()
        (self.waiters / str(pid)).write_text(
            f"pid={pid} class=lane limit=1 ticket=1:1 since=x job=- cmd=fixture start={'0' * 64}")
        result = self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(result.returncode, 75, "command text forged a fixed-head identity")

    def test_legacy_command_tokens_cannot_forge_head_fields(self):
        records = [
            "pid=4242 class=lane limit=1 cmd=echo pid=1",
            "pid=4242 class=lane limit=1 cmd=echo start=forged",
            "pid=4242 class=lane limit=1 cmd=echo class=ci",
            "pid=4242 class=lane limit=1 cmd=echo limit=2",
            "pid=4242 since=x job=- cmd=echo pid=1",
        ]
        anchor = "if not args:\n"
        injection = (
            f"records = {records!r}\n"
            "print(json.dumps([record_head(text) for text in records]))\n"
            "raise SystemExit(0)\n" + anchor)
        binary = self.instrument("record-head-probe-wrk", anchor, injection)
        result = subprocess.run([str(binary), "heavy"], env=self.env,
                                capture_output=True, text=True, timeout=5, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        observed = [tuple(row) for row in json.loads(result.stdout)]
        expected = [
            (4242, None, "lane", 1),
            (4242, None, "lane", 1),
            (4242, None, "lane", 1),
            (4242, None, "lane", 1),
            (4242, None, "lane", None),
        ]
        self.assertEqual(observed, expected,
                         "legacy command text forged a fixed head value")

    def test_legacy_command_start_cannot_retire_a_live_waiter(self):
        pid = os.getpid()
        record = self.waiters / str(pid)
        record.write_text(
            f"pid={pid} since=x job=- cmd=echo start=forged")
        status = self.run_wrk("status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertTrue(record.exists(), "legacy command start retired a live waiter")
        log_path = self.base / "heavy.log"
        rows = [json.loads(line) for line in log_path.read_text().splitlines()] \
            if log_path.exists() else []
        retired = [row for row in rows if row.get("kind") == "waiter_retired"
                   and row.get("record") == str(pid)]
        self.assertEqual(retired, [], "legacy command start was logged as owner death")

    def test_wait_signals_remove_own_record_and_exit_with_signal_status(self):
        for sig, expected in ((signal.SIGHUP, 129), (signal.SIGTERM, 143)):
            with self.subTest(signal=sig):
                holder = self.start("signal-holder-" + str(sig))
                try:
                    waiter = self.spawn("signal-waiter-" + str(sig), WRK_HEAVY_WAIT_CAP="10")
                    info = self.queued("signal-waiter-" + str(sig))
                    record_pid = re.match(r"pid=(\d+)", info).group(1)
                    record = self.waiters / record_pid
                    self.assertTrue(record.exists())
                    os.kill(int(record_pid), sig)
                    self.assertEqual(waiter.wait(timeout=5), expected)
                    self.assertFalse(record.exists(), "signal left the waiter's reservation behind")
                finally:
                    self.release("signal-holder-" + str(sig))
                    holder.wait(timeout=5)

    def test_inherited_ignored_signals_are_restored_for_command(self):
        for sig, name in ((signal.SIGHUP, "HUP"), (signal.SIGTERM, "TERM")):
            with self.subTest(signal=sig):
                command = f"kill -{name} $$; echo survived"
                if sig == signal.SIGHUP:
                    args = ["nohup", str(WRK), "heavy", "--", "sh", "-c", command]
                else:
                    args = ["sh", "-c", 'trap "" TERM; exec "$1" heavy -- sh -c "$2"',
                            "sh", str(WRK), command]
                result = subprocess.run(args, env=self.env, capture_output=True,
                                        text=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 0,
                                 "heavy changed an inherited SIG_IGN disposition: "
                                 + result.stderr)
                self.assertIn("survived", result.stdout,
                              "heavy changed an inherited SIG_IGN disposition")

    def test_lane_defer_guard_is_monotonic_and_never_preempts_holder(self):
        holder = self.start("lane-guard-holder")
        older = self.spawn("stopped-older")
        older_info = self.queued("stopped-older")
        older_pid = int(re.match(r"pid=(\d+)", older_info).group(1))
        os.kill(older_pid, signal.SIGSTOP)
        try:
            binary = self.instrument("wall-step-lane-guard-wrk", "started_at = time.monotonic()",
                                     "started_at = time.monotonic()\ntime.time = lambda: 10**12")
            younger = self.spawn("guarded-younger", binary=binary,
                                 WRK_HEAVY_LANE_DEFER_MAX="1.2", WRK_HEAVY_WAIT_CAP="10")
            self.queued("guarded-younger")
            time.sleep(.35)
            self.assertFalse(self.started("guarded-younger"), "wall-clock jump ended lane deferral early")
            self.assertIsNone(holder.poll(), "the guard preempted a slot holder")
            self.release("lane-guard-holder")
            self.assertEqual(holder.wait(timeout=5), 0)
            time.sleep(.35)
            self.assertFalse(self.started("guarded-younger"),
                             "wall-clock jump or missing guard ended lane deferral early")
            time.sleep(.8)
            self.until(lambda: self.started("guarded-younger"),
                       "lane waiter did not take a free slot after its defer bound")
            self.release("guarded-younger")
            self.assertEqual(younger.wait(timeout=5), 0)
            os.kill(older_pid, signal.SIGCONT)
            self.until(lambda: self.started("stopped-older"), "resumed older waiter did not finish")
            self.release("stopped-older")
            self.assertEqual(older.wait(timeout=5), 0)
        finally:
            try:
                os.kill(older_pid, signal.SIGCONT)
            except ProcessLookupError:
                pass

    def test_lane_defer_zero_disables_and_invalid_values_refuse(self):
        holder = self.start("lane-zero-holder")
        older = self.spawn("lane-zero-older")
        older_info = self.queued("lane-zero-older")
        older_pid = int(re.match(r"pid=(\d+)", older_info).group(1))
        os.kill(older_pid, signal.SIGSTOP)
        try:
            younger = self.spawn("lane-zero-younger", WRK_HEAVY_LANE_DEFER_MAX="0")
            self.queued("lane-zero-younger")
            self.release("lane-zero-holder")
            self.assertEqual(holder.wait(timeout=5), 0)
            self.until(lambda: self.started("lane-zero-younger"),
                       "zero did not disable lane deferral")
            self.release("lane-zero-younger")
            self.assertEqual(younger.wait(timeout=5), 0)
            os.kill(older_pid, signal.SIGCONT)
            self.until(lambda: self.started("lane-zero-older"), "older waiter did not drain")
            self.release("lane-zero-older")
            self.assertEqual(older.wait(timeout=5), 0)
        finally:
            try:
                os.kill(older_pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        for value in ("invalid", "-1", "nan"):
            with self.subTest(value=value):
                result = self.run_wrk("--", "true", WRK_HEAVY_LANE_DEFER_MAX=value)
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_fifo_reserves_only_eligible_slots(self):
        # Our live test pid is a deterministic older lane; it reserves slot 0
        # until the fixture file is removed. Slot 1 must remain available.
        self.plant_lane(os.getpid())
        result = self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(result.returncode, 75, "younger lane overtook a live older ticket")
        result = self.run_wrk("--", "true", WRK_HEAVY_MAX="2")
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.waiters / str(os.getpid())).unlink()
        self.assertEqual(self.run_wrk("--", "true").returncode, 0)

    def durable(self, expired=False, keyed=True, binary=WRK):
        self.start("holder")
        old = self.spawn("a-old", key="job-A" if keyed else None, binary=binary,
                         WRK_HEAVY_WAIT_CAP=".6")
        original = self.ticket(self.queued("a-old"))
        self.assertEqual(old.wait(timeout=5), 75, "A must hit the slot wait cap")
        records = self.position_records()
        if keyed:
            self.assertEqual(len(records), 1, "keyed cap did not preserve a position")
            self.assertEqual(tuple(records[0]["ticket"]), original)
            status = self.run_wrk("status").stdout
            self.assertIn("position ", status)
            self.assertIn("key=job-A", status)
            self.assertIn("expiry=", status)
            if expired:
                for path in self.positions.glob("key-*.json"):
                    record = json.loads(path.read_text())
                    record["expiry"] = time.time() - 1
                    path.write_text(json.dumps(record))
        else:
            self.assertEqual(records, [], "unkeyed cap must not save a place")
        # B must start its first lane scan only after A's new record is
        # visible. Otherwise the documented already-scanned-pass exception
        # can legitimately let B acquire while this test releases the holder.
        gate = self.base / "b-scan-gate"
        self.files.append(gate)
        anchor = '                lane_limit = lane_reserved()\n'
        gated = self.instrument("b-gated-wrk", anchor,
                                f"                while not os.path.exists({str(gate)!r}):\n"
                                "                    time.sleep(.02)\n" + anchor)
        b = self.spawn("b", binary=gated)
        try:
            bticket = self.ticket(self.queued("b"))
        except AssertionError as exc:
            raise AssertionError(str(exc) + ": " + (self.base / "b.out").read_text()) from exc
        a = self.spawn("a-new", key="job-A" if keyed else None, binary=binary)
        aticket = self.ticket(self.queued("a-new"))
        if keyed and not expired:
            self.assertEqual(aticket, original, "original ticket was not reused within grace")
            self.assertLess(aticket, bticket)
            order = [("a-new", a), ("b", b)]
        else:
            self.assertGreater(aticket, bticket, "fresh re-queue jumped ahead of B")
            order = [("b", b), ("a-new", a)]
        gate.touch()
        self.release("holder")
        for name, proc in order:
            self.until(lambda: self.started(name), f"wrong re-queue acquisition order: {name}")
            actual = (self.base / "order").read_text().splitlines()
            self.assertEqual(actual[-1], name)
            if name == "a-new":
                self.assertEqual(self.position_records(), [], "acquisition did not consume the position")
            self.release(name)
            self.assertEqual(proc.wait(timeout=5), 0, (self.base / (name + ".out")).read_text())

    def test_position_reused_within_grace(self):
        self.durable()

    def test_expired_position_requeues_fresh(self):
        self.durable(expired=True)

    def test_unkeyed_requeues_fresh(self):
        self.durable(keyed=False)

    def test_dead_and_mixed_version_records_reserve_nothing(self):
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait(timeout=5)
        self.plant_lane(dead.pid)
        (self.waiters / "legacy").write_text(
            f"pid={os.getpid()} class=lane limit=1 since=x job=- cmd=old ticket=1:1")
        result = self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(result.returncode, 0, "dead or ticketless record reserved a slot")
        status = self.run_wrk("status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertFalse((self.waiters / str(dead.pid)).exists(), "status did not clean a dead waiter")

    def test_ticketless_ci_keeps_its_existing_reservation(self):
        (self.waiters / "legacy-ci").write_text(
            f"pid={os.getpid()} class=ci limit=1 since=x job=- cmd=old-ci")
        result = self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(result.returncode, 75,
                         "ticketless live CI record lost its existing reservation")
        self.assertEqual(self.run_wrk("--", "true", WRK_HEAVY_CLASS="ci").returncode, 0,
                         "CI unexpectedly deferred to another CI waiter")
        (self.waiters / "legacy-ci").unlink()
        self.assertEqual(self.run_wrk("--", "true").returncode, 0)

    def test_status_ticket_order_and_expiry_cleanup(self):
        self.start("holder")
        for name in ("first", "second", "third"):
            self.spawn(name)
            self.queued(name)
        status = self.run_wrk("status").stdout
        lines = [line for line in status.splitlines() if line.startswith("waiter ")]
        self.assertEqual([line.split()[-1] for line in lines], ["first", "second", "third"])
        tickets = [self.ticket(line) for line in lines]
        self.assertEqual(tickets, sorted(tickets))
        (self.position_path("old")).write_text(json.dumps(
            {"key": "old", "ticket": [1, 1], "expiry": time.time() - 1}))
        self.assertNotIn("key=old", self.run_wrk("status").stdout)
        self.assertFalse((self.position_path("old")).exists())

    def test_key_validation_and_env_option_precedence(self):
        for key in ("", "." * 65, "a/b", "white space", "é", "\n"):
            result = self.run_wrk("--queue-key", key, "--", "true", LC_ALL="en_US.UTF-8")
            self.assertEqual(result.returncode, 78, f"invalid key accepted: {key!r}: {result.stderr}")
        for key in (".", "..", "valid-key_1.2", "A" * 64):
            result = self.run_wrk("--queue-key", key, "--", "true")
            self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_wrk("--queue-key", "valid", "--", "true", WRK_HEAVY_QUEUE_KEY="bad/key")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_wrk("--", "true", WRK_HEAVY_QUEUE_KEY="é")
        self.assertEqual(result.returncode, 78)
        for grace in ("bad", "-1", "nan", "inf"):
            result = self.run_wrk("--", "true", WRK_HEAVY_REQUEUE_GRACE=grace)
            self.assertEqual(result.returncode, 2, f"invalid grace accepted: {grace}")

    def test_odd_positions_are_ignored_without_following_or_blocking(self):
        victim = self.base / "victim"
        victim.write_text("unchanged")
        (self.position_path("link")).symlink_to(victim)
        os.mkfifo(self.position_path("fifo"))
        (self.position_path("bad")).write_text("not JSON")
        for key in ("link", "fifo", "bad"):
            result = self.run_wrk("--queue-key", key, "--", "true")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(victim.read_text(), "unchanged", "position symlink target changed")
        self.assertNotIn("Traceback", self.run_wrk("status").stderr)
        bad = self.position_path("malformed")
        for value in ([], {"key": []}, {"key": "malformed", "ticket": [True, 1], "expiry": 1},
                      {"key": "malformed", "ticket": [1, 1], "expiry": float("inf")},
                      {"key": "malformed", "ticket": [1, 1], "expiry": 10**1000}):
            bad.write_text(json.dumps(value))
            result = self.run_wrk("--queue-key", "malformed", "--", "true")
            self.assertEqual(result.returncode, 0, result.stderr)
        hardlink = self.position_path("hard")
        os.link(victim, hardlink)
        self.assertEqual(self.run_wrk("--queue-key", "hard", "--", "true").returncode, 0)
        self.assertEqual(victim.read_text(), "unchanged")

    def test_deeply_nested_position_is_ignored(self):
        self.position_path("deep").write_text("[" * 1100 + "0" + "]" * 1100)
        result = self.run_wrk("--queue-key", "deep", "--", "true")
        self.assertEqual(result.returncode, 0, "nested malformed position crashed the queue reader: " + result.stderr)
        self.assertNotIn("Traceback", self.run_wrk("status").stderr)

    def test_untrusted_positions_directory_refused(self):
        self.positions.rmdir()
        target = self.base / "elsewhere"
        target.mkdir()
        self.positions.symlink_to(target, target_is_directory=True)
        result = self.run_wrk("--queue-key", "A", "--", "true")
        self.assertEqual(result.returncode, 78)
        self.assertEqual(list(target.iterdir()), [])
        self.positions.unlink()
        self.positions.mkdir(mode=0o777)
        self.positions.chmod(0o777)
        self.assertEqual(self.run_wrk("--queue-key", "A", "--", "true").returncode, 78)

    def instrument(self, name, old, new, count=1):
        source = WRK.read_text()
        self.assertEqual(source.count(old), count, f"instrumentation anchor changed: {old}")
        binary = self.base / name
        binary.write_text(source.replace(old, new, count))
        binary.chmod(0o755)
        return binary

    def instrument_many(self, name, changes):
        source = WRK.read_text()
        for old, new in changes:
            self.assertEqual(source.count(old), 1,
                             f"instrumentation anchor changed: {old}")
            source = source.replace(old, new, 1)
        binary = self.base / name
        binary.write_text(source)
        binary.chmod(0o755)
        return binary

    def test_foreign_owned_position_is_ignored(self):
        self.start("holder")
        path = self.position_path("A")
        path.write_text(json.dumps({"key": "A", "ticket": [1, 1],
                                    "expiry": time.time() + 600}))
        # No privileged chown in CI: change only this inode's fstat uid at
        # the real read call site; the production ownership predicate runs.
        binary = self.instrument("foreign-wrk", "            st = os.fstat(f.fileno())\n",
                                 "            st = os.fstat(f.fileno())\n"
                                 f"            if st.st_ino == {path.stat().st_ino}:\n"
                                 "                fields = list(st)\n"
                                 "                fields[4] = 42424242\n"
                                 "                st = os.stat_result(fields)\n")
        self.spawn("foreign", key="A", binary=binary)
        self.assertGreater(self.ticket(self.queued("foreign")), (1, 1),
                           "foreign-owned position was reused")

    def test_expiry_boundary_and_wall_clock_ticket_with_monotonic_cap(self):
        self.start("holder")
        (self.position_path("A")).write_text(json.dumps(
            {"key": "A", "ticket": [1, 1], "expiry": 100.0}))
        binary = self.instrument("clock-wrk", "positions_fd = -1\n",
                                 "time.time = lambda: 100.0\n"
                                 "time.time_ns = lambda: 50\npositions_fd = -1\n")
        proc = self.spawn("boundary", key="A", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
        ticket = self.ticket(self.queued("boundary"))
        self.assertEqual(ticket[0], 50, "ticket did not use the wall clock")
        self.assertNotEqual(ticket, (1, 1), "position reused exactly at expiry")
        self.assertEqual(proc.wait(timeout=5), 75, "wall-clock step broke the monotonic cap")

    def test_same_timestamp_uses_enqueue_pid_and_equal_ticket_never_stalls(self):
        binary = self.instrument("ties-wrk", "ticket = (time.time_ns(), os.getpid())",
                                 f"ticket = (100, {os.getpid() + 1})")
        self.plant_lane(os.getpid(), ticket=f"100:{os.getpid()}")
        self.assertEqual(self.run_wrk("--", "true", binary=binary,
                                     WRK_HEAVY_WAIT_CAP=".6").returncode, 75)
        self.plant_lane(os.getpid(), ticket=f"100:{os.getpid() + 1}")
        self.assertEqual(self.run_wrk("--", "true", binary=binary).returncode, 0,
                         "equal tickets waited on one another")

    def test_ci_over_older_lane_and_guard_does_not_waive_fifo(self):
        self.start("holder")
        self.spawn("lane")
        self.queued("lane")
        ci = self.spawn("ci", WRK_HEAVY_CLASS="ci")
        self.queued("ci")
        self.release("holder")
        self.until(lambda: self.started("ci"), "CI did not overtake the older lane")
        self.assertFalse(self.started("lane"), "lane ran ahead of CI")
        self.release("ci")
        self.assertEqual(ci.wait(timeout=5), 0)
        self.until(lambda: self.started("lane"), "lane did not drain after CI")
        self.release("lane")
        # The existing CI guard can be disabled, but older lanes still reserve.
        self.plant_lane(os.getpid())
        self.assertEqual(self.run_wrk("--", "true", WRK_HEAVY_CI_DEFER_MAX="0",
                                     WRK_HEAVY_WAIT_CAP=".6").returncode, 75)

    def test_pass_already_scanned_and_new_publish_window(self):
        holder = self.start("holder")
        # Park exactly after the production lane scan, not for a guessed time.
        gate, scanned = self.base / "gate", self.base / "scanned"
        self.files.append(gate)
        anchor = '            for i, sfd in enumerate(slot_fds):\n'
        binary = self.instrument("scan-wrk", anchor,
                                 f"            open({str(scanned)!r}, 'w').close()\n"
                                 f"            while not os.path.exists({str(gate)!r}):\n"
                                 "                time.sleep(.02)\n" + anchor)
        self.spawn("in-flight", binary=binary)
        try:
            self.until(scanned.exists, "pass did not reach the scan barrier")
        except AssertionError as exc:
            output = (self.base / "in-flight.out").read_text()
            raise AssertionError(str(exc) + ": " + output) from exc
        self.plant_lane(os.getpid())
        self.release("holder")
        self.assertEqual(holder.wait(timeout=5), 0)
        gate.touch()
        self.until(lambda: self.started("in-flight"),
                   "an already-scanned pass unexpectedly re-read the new record")
        self.release("in-flight")
        # A new pass now sees that same visible older record and must defer.
        self.assertEqual(self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6").returncode, 75)

    def test_crash_after_position_publish_and_during_publish(self):
        self.start("holder")
        anchor = '                end_defer("cap")\n                end_lane_defer("cap")\n                save_position()\n'
        binary = self.instrument("crash-after-wrk", anchor, anchor + "                os._exit(75)\n")
        old = self.spawn("crashed", key="A", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
        ticket = self.ticket(self.queued("crashed"))
        self.assertEqual(old.wait(timeout=5), 75)
        self.assertTrue(self.position_records(), "crash lost a published position")
        self.spawn("retry", key="A")
        self.assertEqual(self.ticket(self.queued("retry")), ticket)
        # A process crash before rename leaves only a dot file, never a
        # partially visible position. It cannot reserve a slot or be reused.
        anchor = "            os.replace(tmp, position_name(queue_key),\n"
        binary = self.instrument("crash-mid-wrk", anchor,
                                 "            os._exit(75)\n" + anchor)
        mid = self.spawn("mid", key="B", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
        mid_ticket = self.ticket(self.queued("mid"))
        self.assertEqual(mid.wait(timeout=5), 75)
        self.assertTrue(any(p.name.startswith(".position-") for p in self.positions.iterdir()))
        self.spawn("fresh-B", key="B")
        self.assertGreater(self.ticket(self.queued("fresh-B")), mid_ticket)
        self.release("holder")
        self.until(lambda: self.started("retry"), "dead crashed waiter blocked its retry")

    def test_simultaneous_keyed_retries_and_env_key(self):
        self.start("holder")
        original = (1, 1)
        (self.position_path("A")).write_text(json.dumps(
            {"key": "A", "ticket": original, "expiry": time.time() + 600}))
        # Start both before waiting for either publication. Sharing a key is
        # allowed; equality must not produce a mutual reservation deadlock.
        a = self.spawn("same-a", key="A")
        b = self.spawn("same-b", WRK_HEAVY_QUEUE_KEY="A")
        self.assertEqual(self.ticket(self.queued("same-a")), original)
        self.assertEqual(self.ticket(self.queued("same-b")), original)
        self.release("holder")
        self.until(lambda: self.started("same-a") or self.started("same-b"),
                   "equal keyed tickets stalled")
        first = "same-a" if self.started("same-a") else "same-b"
        second = "same-b" if first == "same-a" else "same-a"
        self.assertEqual(self.position_records(), [], "acquisition did not consume the shared place")
        self.release(first)
        self.until(lambda: self.started(second), "second same-key waiter did not drain")
        self.release(second)
        self.assertEqual(a.wait(timeout=5), 0)
        self.assertEqual(b.wait(timeout=5), 0)

    def test_status_does_not_remove_a_refreshed_position(self):
        path = self.position_path("A")
        path.write_text(json.dumps({"key": "A", "ticket": [1, 1], "expiry": 1}))
        renewed = {"key": "A", "ticket": [1, 1], "expiry": time.time() + 600}
        # Replace after the real expired-record read and before its cleanup.
        # The inode comparison must preserve the new cap publication.
        anchor = '                if record["expiry"] <= time.time():\n'
        binary = self.instrument("refresh-wrk", anchor,
                                 f"                replacement = {str(self.base / 'replacement')!r}\n"
                                 f"                open(replacement, 'w').write({json.dumps(renewed)!r})\n"
                                 "                os.replace(replacement, name, dst_dir_fd=pfd)\n" + anchor)
        self.assertEqual(self.run_wrk("status", binary=binary).returncode, 0)
        self.assertEqual(json.loads(path.read_text()), renewed)

    def test_position_publish_uses_the_opened_directory_after_a_swap(self):
        self.start("holder")
        opened = self.base / "original-positions"
        anchor = '    tmp = ".position-" + os.urandom(16).hex()\n'
        binary = self.instrument("swap-wrk", anchor,
                                 f"    os.rename(positions_dir, {str(opened)!r})\n"
                                 "    os.mkdir(positions_dir)\n" + anchor)
        proc = self.spawn("swapped", key="A", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
        self.queued("swapped")
        self.assertEqual(proc.wait(timeout=5), 75)
        self.assertEqual(list(self.positions.iterdir()), [], "publish resolved the replaced path")
        record = json.loads((opened / self.position_path("A").name).read_text())
        self.assertEqual(record["key"], "A")

    def test_acquisition_consumes_position_published_while_it_was_queued(self):
        self.start("holder")
        old = self.spawn("older-A", key="A", WRK_HEAVY_WAIT_CAP="3")
        original = self.ticket(self.queued("older-A"))
        retry = self.spawn("queued-A", key="A")
        self.assertGreater(self.ticket(self.queued("queued-A")), original)
        self.assertEqual(old.wait(timeout=6), 75)
        self.assertEqual(tuple(self.position_records()[0]["ticket"]), original)
        self.release("holder")
        self.until(lambda: self.started("queued-A"), "queued same-key waiter did not acquire")
        self.assertEqual(self.position_records(), [],
                         "acquisition left a same-key position published during its wait")
        self.release("queued-A")
        self.assertEqual(retry.wait(timeout=5), 0)

    def test_case_distinct_keys_keep_independent_positions(self):
        self.start("holder")
        tickets = {}
        for key, name in (("A", "upper-capped"), ("a", "lower-capped")):
            proc = self.spawn(name, key=key, WRK_HEAVY_WAIT_CAP=".6")
            tickets[key] = self.ticket(self.queued(name))
            self.assertEqual(proc.wait(timeout=5), 75)
        self.assertEqual({r["key"] for r in self.position_records()}, {"A", "a"},
                         "case-distinct queue keys lost an independent position")
        for key, name in (("A", "upper-retry"), ("a", "lower-retry")):
            self.spawn(name, key=key)
            self.assertEqual(self.ticket(self.queued(name)), tickets[key])

    def test_mutants_break_the_named_invariants(self):
        mutations = [
            ("fifo", [
                ('lane_limit = lane_reserved()\n', 'lane_limit = 0\n'),
            ], "test_fifo_reserves_only_eligible_slots",
             "younger lane overtook a live older ticket"),
            ("reuse", [('            ticket = tuple(record["ticket"])',
                         '            pass  # mutant: discard the saved ticket')],
             "test_position_reused_within_grace", "original ticket was not reused within grace"),
            ("dead", [('        if pid > 0 and live is False:\n', '        if False:\n')],
             "test_dead_and_mixed_version_records_reserve_nothing",
             "status did not clean a dead waiter"),
            ("no-owner-identity", [
                ('    if first != start:\n        return False, "start-mismatch"\n',
                 '    if False:\n        return False, "start-mismatch"\n'),
                ('    if second != start:\n        return False, "start-mismatch"\n',
                 '    if False:\n        return False, "start-mismatch"\n'),
            ],
             "test_pid_reuse_mismatch_stops_reserving_and_status_retires_once",
             "pid-reuse mismatch reserves nothing"),
            ("eperm-dead", [('    except PermissionError:\n        return True, "eperm"\n',
                             '    except PermissionError:\n        return False, "dead"\n')],
             "test_eperm_identity_states", "EPERM matching identity state had wrong result",
            ),
            ("unknown-dead", [('    if first is None:\n        log_owner_identity_unknown(pid, record, "start-read-unknown")\n        return None, "identity-unknown"\n',
                                '    if first is None:\n        log_owner_identity_unknown(pid, record, "start-read-unknown")\n        return False, "dead"\n')],
             "test_unknown_start_identity_keeps_record_and_logs_once",
             "unknown owner identity stopped reserving"),
            ("legacy-headscan", [
                ('    if fixed_head and len(toks) > 4 and toks[4].startswith("start="):\n'
                 '        start = toks[4][6:]\n',
                 '    for tok in toks:\n'
                 '        if tok.startswith("pid="):\n'
                 '            try:\n'
                 '                pid = int(tok[4:])\n'
                 '            except ValueError:\n'
                 '                pass\n'
                 '        elif tok.startswith("start="):\n'
                 '            start = tok[6:]\n'
                 '        elif tok.startswith("class=") and tok[6:] in ("ci", "lane"):\n'
                 '            cls = tok[6:]\n'
                 '        elif tok.startswith("limit="):\n'
                 '            try:\n'
                 '                lim = int(tok[6:])\n'
                 '            except ValueError:\n'
                 '                pass\n'),
            ], "test_legacy_command_start_cannot_retire_a_live_waiter",
             "legacy command start retired a live waiter"),
            ("no-lane-bound", [('if lane_defer_total + (now - lane_defer_mark) >= lane_defer_max:\n',
                                'if False:\n')],
             "test_lane_defer_guard_is_monotonic_and_never_preempts_holder",
             "lane waiter did not take a free slot after its defer bound"),
            ("no-hup-handler", [('    previous_hup_handler = signal.signal(signal.SIGHUP, wait_signal_handler)\n',
                                  '    previous_hup_handler = signal.signal(signal.SIGHUP, signal.SIG_DFL)\n')],
             "test_wait_signals_remove_own_record_and_exit_with_signal_status",
             ("129", "signal left the waiter's reservation behind")),
            ("reset-inherited-ignore", [
                ("    signal.signal(signal.SIGHUP, previous_hup_handler)\n",
                 "    signal.signal(signal.SIGHUP, signal.SIG_DFL)\n"),
                ("    signal.signal(signal.SIGTERM, previous_term_handler)\n",
                 "    signal.signal(signal.SIGTERM, signal.SIG_DFL)\n"),
            ], "test_inherited_ignored_signals_are_restored_for_command",
             "heavy changed an inherited SIG_IGN disposition"),
        ]
        for name, changes, case, invariant in mutations:
            with self.subTest(invariant=invariant):
                binary = self.instrument_many("mutant-" + name, changes)
                result = subprocess.run(
                    [sys.executable, str(Path(__file__).resolve()), "HeavyQueue." + case],
                    env=dict(self.env, WRK_QUEUE_TEST_BIN=str(binary)),
                    capture_output=True, text=True, timeout=45, check=False)
                self.assertNotEqual(result.returncode, 0,
                                    "mutant survived: " + repr(invariant))
                self.assertIn("AssertionError:", result.stderr)
                expected = invariant if isinstance(invariant, tuple) else (invariant,)
                self.assertTrue(any(item in result.stderr for item in expected),
                                "mutant did not fail the named assertion: " + repr(expected)
                                + "\n" + result.stderr[-1800:])
                self.assertNotIn("ERROR:", result.stderr,
                                 "a crash is not assertion RED\n" + result.stderr[-1800:])


if __name__ == "__main__":
    unittest.main(verbosity=2)
