"""hk 1407: real heavy entry-point tests, using only file-controlled fixtures."""

import ast
import io
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
from unittest import mock
from types import SimpleNamespace


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
                        WRK_HEAVY_REQUEUE_GRACE="600", WRK_HEAVY_LANE_DEFER_MAX="1800",
                        WRK_TEST_MODE="1")
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
        anchor = '            lane_limit = lane_reserved() if hclass == "lane" else 0\n'
        gated = self.instrument("b-gated-wrk", anchor,
                                f"            while not os.path.exists({str(gate)!r}):\n"
                                "                time.sleep(.02)\n" + anchor)
        b = self.spawn("b", binary=gated)
        bticket = self.ticket(self.queued("b"))
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

    def instrument(self, name, old, new):
        source = WRK.read_text()
        self.assertEqual(source.count(old), 1, f"instrumentation anchor changed: {old}")
        binary = self.base / name
        binary.write_text(source.replace(old, new, 1))
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
        anchor = '            lane_limit = lane_reserved() if hclass == "lane" else 0\n'
        binary = self.instrument("scan-wrk", anchor, anchor +
                                 f"            open({str(scanned)!r}, 'w').close()\n"
                                 f"            while not os.path.exists({str(gate)!r}):\n"
                                 "                time.sleep(.02)\n")
        self.spawn("in-flight", binary=binary)
        self.until(scanned.exists, "pass did not reach the scan barrier")
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
        anchor = '                end_defer("cap")\n                save_position()\n'
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

    def plant_owner(self, start="forged", cls="lane"):
        path = self.waiters / "owner"
        path.write_text(f"pid={os.getpid()} class={cls} limit=1 ticket=1:1 "
                        f"start={start} since=1900-01-01 job=- cmd=fixture")
        return path

    def owner_probe(self, name, injection):
        return self.instrument(name, "def alive(pid, strict=False):\n", injection + "\n\ndef alive(pid, strict=False):\n")

    def events(self, kind):
        log = self.base / "heavy.log"
        return [r for r in map(json.loads, log.read_text().splitlines()) if r["kind"] == kind] if log.exists() else []

    def test_owner_pid_reuse_retires_and_audits_once(self):
        for cls in ("lane", "ci"):
            path = self.plant_owner(cls=cls)
            result = self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6")
            self.assertEqual(result.returncode, 0, "different process identity reserved capacity: " + result.stderr)
            self.assertTrue(path.exists(), "reservation reader performed status cleanup")
            self.assertEqual(self.run_wrk("status").returncode, 0)
            self.assertFalse(path.exists(), "status did not retire mismatched owner")
            self.run_wrk("status")
        rows = self.events("waiter.retired")
        self.assertEqual(len(rows), 2, "retirement must audit exactly once per record")
        self.assertTrue(all(r["record"] == "owner" and r["owner_pid"] == os.getpid()
                            and r["reason"] == "start-mismatch" for r in rows))

    def eperm_owner(self, observed, start="fixture", cls="lane"):
        path = self.plant_owner(start=start, cls=cls)
        binary = self.owner_probe("eperm-wrk",
            "_real_kill = os.kill\n"
            "def _kill_probe(pid, sig):\n"
            f"    if pid == {os.getpid()} and sig == 0: raise PermissionError(1, 'fixture')\n"
            "    return _real_kill(pid, sig)\nos.kill = _kill_probe\n")
        source = binary.read_text()
        anchor = "def process_start(pid):\n"
        self.assertEqual(source.count(anchor), 1)
        binary.write_text(source.replace(anchor, anchor +
            f"    if pid == {os.getpid()}: return {observed!r}\n", 1))
        return path, binary

    def test_owner_eperm_matching_retains_reservation(self):
        for cls in ("lane", "ci"):
            path, binary = self.eperm_owner("fixture", cls=cls)
            result = self.run_wrk("--", "true", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
            self.assertEqual(result.returncode, 75, "EPERM matching identity lost reservation")
            self.assertEqual(self.run_wrk("status", binary=binary).returncode, 0)
            self.assertTrue(path.exists(), "EPERM matching owner was retired")
        self.assertEqual(self.events("waiter.retired"), [])
        self.assertEqual(self.events("waiter.owner_unknown"), [])

    def test_owner_eperm_mismatch_retires(self):
        path, binary = self.eperm_owner("different")
        result = self.run_wrk("--", "true", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(result.returncode, 0, "EPERM mismatching owner reserved capacity")
        self.assertEqual(self.run_wrk("status", binary=binary).returncode, 0)
        self.assertFalse(path.exists(), "EPERM mismatching owner was retained")
        self.assertEqual(self.events("waiter.retired")[0]["reason"], "start-mismatch")

    def test_owner_eperm_unreadable_retains_reservation(self):
        path, binary = self.eperm_owner(None)
        result = self.run_wrk("--", "true", binary=binary, WRK_HEAVY_WAIT_CAP=".6")
        self.assertEqual(result.returncode, 75, "EPERM unreadable identity lost reservation")
        self.assertEqual(len(self.events("waiter.owner_unknown")), 1)
        self.assertEqual(self.run_wrk("status", binary=binary).returncode, 0)
        self.assertTrue(path.exists(), "EPERM unreadable owner was retired")
        self.assertEqual(self.events("waiter.retired"), [])

    def test_owner_eperm_legacy_retains_reservation(self):
        path, binary = self.eperm_owner(None)
        path.write_text(path.read_text().replace(" start=fixture", ""))
        self.assertEqual(self.run_wrk("--", "true", binary=binary,
                                     WRK_HEAVY_WAIT_CAP=".6").returncode, 75)
        self.run_wrk("status", binary=binary)
        self.assertTrue(path.exists(), "EPERM legacy owner was retired")

    def test_owner_unknown_keeps_record_and_logs_once(self):
        path = self.plant_owner()
        binary = self.owner_probe("unknown-wrk",
            "import builtins\n_real_open = builtins.open\n_real_run = subprocess.run\n"
            "def _open_probe(path, *args, **kwargs):\n"
            "    if str(path).startswith('/proc/'): raise PermissionError('fixture')\n"
            "    return _real_open(path, *args, **kwargs)\n"
            "def _run_probe(args, *a, **kw):\n"
            "    if args[0] == 'ps': raise subprocess.TimeoutExpired(args, 2)\n"
            "    return _real_run(args, *a, **kw)\n"
            "builtins.open = _open_probe\nsubprocess.run = _run_probe\n")
        result = self.run_wrk("--", "true", binary=binary, WRK_HEAVY_WAIT_CAP="1.1")
        self.assertEqual(result.returncode, 75, "unknown identity must retain reservation")
        self.assertTrue(path.exists())
        self.assertEqual(len(self.events("waiter.owner_unknown")), 1,
                         "unreadable identity must log once per run")
        self.assertEqual(self.run_wrk("status", binary=binary).returncode, 0)
        self.assertTrue(path.exists(), "unknown owner was deleted")
        self.assertEqual(self.events("waiter.retired"), [])

    def test_start_identity_is_in_fixed_head_only(self):
        holder = self.start("identity-holder")
        text = self.lock.read_text()
        self.assertRegex(text.split()[4], r"^start=(macos|linux):",
                         "new owner identity missing from fixed head")
        self.release("identity-holder")
        self.assertEqual(holder.wait(timeout=5), 0)
        self.plant_lane(os.getpid())
        path = self.waiters / str(os.getpid())
        path.write_text(path.read_text() + " start=forged")
        self.assertEqual(self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6").returncode, 75,
                         "command text forged a process identity")
        self.run_wrk("status")
        self.assertTrue(path.exists())

    def test_lane_stopped_waiter_bound_and_no_preemption(self):
        holder = self.start("bound-holder")
        older = self.spawn("stopped-older")
        info = self.queued("stopped-older")
        pid = int(info.split()[0].split("=")[1])
        os.kill(pid, signal.SIGSTOP)
        try:
            younger = self.spawn("bound-younger", WRK_HEAVY_LANE_DEFER_MAX="2")
            self.queued("bound-younger")
            start = time.monotonic()
            POLL.wait(.6)
            self.assertFalse(self.started("bound-younger"), "lane guard fired before its bound")
            self.assertIsNone(holder.poll(), "guard preempted the holder")
            self.release("bound-holder")
            self.assertEqual(holder.wait(timeout=5), 0)
            self.until(lambda: self.started("bound-younger"), "stopped older waiter blocked past lane bound", timeout=5)
            self.assertGreaterEqual(time.monotonic() - start, 1.5)
            self.release("bound-younger")
            self.assertEqual(younger.wait(timeout=5), 0)
        finally:
            os.kill(pid, signal.SIGCONT)
            self.release("stopped-older")
        self.assertEqual(older.wait(timeout=6), 0)

    def test_wait_signals_cleanup_and_exit_codes(self):
        self.start("signal-holder")
        for sig in (signal.SIGHUP, signal.SIGTERM):
            proc = self.spawn("signal-" + str(sig))
            info = self.queued("signal-" + str(sig))
            pid = int(info.split()[0].split("=")[1])
            os.kill(pid, sig)
            self.assertEqual(proc.wait(timeout=5), 128 + sig, "wait signal exit status wrong")
            self.assertFalse((self.waiters / str(pid)).exists(), "wait signal leaked waiter record")
            self.assertFalse(self.started("signal-" + str(sig)))
        self.assertFalse(self.started("signal-" + str(signal.SIGTERM)))
        self.assertFalse(self.started("signal-" + str(signal.SIGHUP)))

    def test_lane_bound_monotonic_and_validation(self):
        for value in ("bad", "-1", "nan"):
            self.assertEqual(self.run_wrk("--", "true", WRK_HEAVY_LANE_DEFER_MAX=value).returncode, 2,
                             "invalid lane guard accepted")
        self.plant_lane(os.getpid())
        self.assertEqual(self.run_wrk("--", "true", WRK_HEAVY_LANE_DEFER_MAX="0").returncode, 0,
                         "zero lane guard did not disable deferral")
        binary = self.instrument("lane-clock", "positions_fd = -1\n",
                                 "time.time = lambda: -1000000.0\npositions_fd = -1\n")
        start = time.monotonic()
        self.assertEqual(self.run_wrk("--", "true", binary=binary,
                                     WRK_HEAVY_LANE_DEFER_MAX="1").returncode, 0,
                         "wall clock step broke lane bound")
        self.assertGreaterEqual(time.monotonic() - start, .9)
        self.assertLess(time.monotonic() - start, 4)

    def test_ancient_command_cannot_forge_start_identity(self):
        path = self.waiters / "ancient"
        path.write_text(f"pid={os.getpid()} since=x job=- cmd=env start=forged")
        self.assertEqual(self.run_wrk("--", "true", WRK_HEAVY_WAIT_CAP=".6").returncode, 0)
        self.assertEqual(self.run_wrk("status").returncode, 0)
        self.assertTrue(path.exists(), "ancient command forged start identity and retired a live owner")
        self.assertEqual(self.events("waiter.retired"), [])

    def test_start_requires_complete_fixed_head(self):
        variants = (
            f"pid={os.getpid()} since=x cmd=env ticket=1:1 start=forged",
            f"pid={os.getpid()} class=lane limit=1 since=x start=forged",
            f"pid={os.getpid()} class=lane cmd=env ticket=1:1 start=forged",
            f"pid={os.getpid()} cmd=env limit=1 ticket=1:1 start=forged",
        )
        for index, info in enumerate(variants):
            path = self.waiters / ("incomplete-head-" + str(index))
            path.write_text(info)
            self.assertEqual(self.run_wrk("status").returncode, 0)
            self.assertTrue(path.exists(), "incomplete head forged identity and retired a live legacy owner")
        self.assertEqual(self.events("waiter.retired"), [])

    def test_base_reader_accepts_new_record(self):
        # These two unchanged functions are the in-repo 1a9ded3 reader logic:
        # record_head reads exactly three tokens; record_ticket reads token four.
        source = WRK.read_text().split("heavy_cmd() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        tree = ast.parse(source)
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef)
                 and n.name in ("record_head", "record_ticket")]
        self.assertEqual(len(nodes), 2)
        ns = {"re": re}
        exec(compile(ast.Module(body=nodes, type_ignores=[]), "base readers", "exec"), ns)
        holder = self.start("base-compatible", WRK_HEAVY_CLASS="ci", WRK_HEAVY_MAX="2")
        info = self.lock.read_text()
        pid = int(info.split()[0].split("=")[1])
        self.assertEqual(ns["record_head"](info), (pid, "ci", 2),
                         "base reader lost pid, class or limit from new record")
        self.assertEqual(ns["record_ticket"](info), self.ticket(info),
                         "base reader lost ticket from new record")
        self.assertTrue(info.split()[4].startswith("start="), "identity must be token five")
        self.release("base-compatible")
        self.assertEqual(holder.wait(timeout=5), 0)

    def test_start_after_pid_mutant_is_assertion_red(self):
        old = 'info = info.replace(" since=", " ticket=%d:%d start=%s since=" %\n                    (*ticket, process_start(os.getpid()) or "unknown"), 1)'
        new = ('info = info.replace(" class=", " start=%s class=" %\n'
               '                    (process_start(os.getpid()) or "unknown"), 1)\n'
               'info = info.replace(" since=", " ticket=%d:%d since=" % ticket, 1)')
        binary = self.instrument("start-after-pid", old, new)
        result = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                 "HeavyQueue.test_base_reader_accepts_new_record"],
            env=dict(self.env, WRK_QUEUE_TEST_BIN=str(binary)), capture_output=True,
            text=True, timeout=40, check=False)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("AssertionError:", result.stderr)
        self.assertIn("base reader lost pid, class or limit", result.stderr)
        self.assertNotIn("ERROR:", result.stderr)

    def test_process_start_platform_methods(self):
        source = WRK.read_text().split("heavy_cmd() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        tree = ast.parse(source)
        node = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "process_start")
        ns = dict(os=os, re=re, sys=SimpleNamespace(platform="darwin"), subprocess=subprocess)
        exec(compile(ast.Module(body=[node], type_ignores=[]), "heavy identity", "exec"), ns)
        response = SimpleNamespace(returncode=0, stdout="  Mon Oct  26 12:00:00 2026  \n")
        with mock.patch.object(subprocess, "run", return_value=response) as run:
            start = ns["process_start"](123)
            self.assertEqual(start, "macos:" + b"  Mon Oct  26 12:00:00 2026  ".hex())
            self.assertEqual(run.call_args.kwargs["env"]["LC_ALL"], "C")
            self.assertEqual(run.call_args.args[0], ["ps", "-o", "lstart=", "-p", "123"])
            self.assertEqual(run.call_args.kwargs["timeout"], 2)
        ns["sys"].platform = "linux"
        stat = "123 (comm with spaces ) and parens) " + " ".join(["S"] + ["0"] * 18 + ["123456"] + ["0"] * 8)
        boot = "01234567-89ab-cdef-0123-456789abcdef"
        with mock.patch("builtins.open", side_effect=lambda path, **kw: io.StringIO(boot if str(path).endswith("boot_id") else stat)):
            self.assertEqual(ns["process_start"](123), "linux:" + boot + ":123456")
        with mock.patch("builtins.open", side_effect=PermissionError("unreadable")):
            self.assertIsNone(ns["process_start"](123))

    def test_macos_same_second_is_alive_different_second_is_dead(self):
        source = WRK.read_text().split("heavy_cmd() {", 1)[1].split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        tree = ast.parse(source)
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef)
                 and n.name in ("alive", "process_start", "owner_alive")]
        proc_os = SimpleNamespace(kill=mock.Mock(), environ={})
        ns = dict(os=proc_os, re=re, sys=SimpleNamespace(platform="darwin"), subprocess=subprocess)
        exec(compile(ast.Module(body=nodes, type_ignores=[]), "macOS owner", "exec"), ns)
        response = SimpleNamespace(returncode=0, stdout="Mon Oct 26 12:00:00 2026\n")
        with mock.patch.object(subprocess, "run", return_value=response):
            original = ns["process_start"](123)
            # ps lstart cannot distinguish same-pid reuse within this second.
            self.assertEqual(ns["owner_alive"](123, original), (True, "same-process"))
            response.stdout = "Mon Oct 26 12:00:01 2026\n"
            self.assertEqual(ns["owner_alive"](123, original), (False, "start-mismatch"))
            response.stdout = " Mon Oct 26 12:00:00 2026\n"
            self.assertEqual(ns["owner_alive"](123, original), (False, "start-mismatch"),
                             "lstart must compare by exact text equality")

    def test_signal_guard_rejects_active_signal_mutants(self):
        shell = (ROOT / "tests/test-wrk-heavy-class.sh").read_text()
        guard = shell.split("""python3 - "$WRK" <<'PY'\n""", 1)[1].split("\nPY\n", 1)[0]
        checker = self.base / "signal-guard.py"
        checker.write_text(guard)
        source = WRK.read_text()
        for name, call in (("kill", "os.kill(pid, signal.SIGTERM)"),
                           ("raise", "signal.raise_signal(signal.SIGTERM)"),
                           ("pthread", "signal.pthread_kill(1, signal.SIGTERM)"),
                           ("alarm", "signal.alarm(1)")):
            with self.subTest(mutant=name):
                binary = self.base / ("signal-mutant-" + name)
                binary.write_text(source.replace("def alive(pid, strict=False):\n",
                    "def alive(pid, strict=False):\n    " + call + "\n", 1))
                result = subprocess.run([sys.executable, str(checker), str(binary)], env=self.env,
                                         capture_output=True, text=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 1, "active signal mutant survived")
                self.assertIn("AssertionError:", result.stderr)
                self.assertIn("a signal path exists", result.stderr)
        result = subprocess.run([sys.executable, str(checker), str(WRK)], env=self.env,
                                 capture_output=True, text=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_owner_mutants_break_invariants(self):
        mutations = [
            ("legacy-context", "    if record_ticket(text) is None:\n", "    if False:\n",
             "test_start_requires_complete_fixed_head", "incomplete head forged identity"),
            ("header-context", '    if (len(fields) < 5 or not fields[0].startswith("pid=") or\n'
             '            fields[1] not in ("class=ci", "class=lane") or\n'
             '            not fields[2].startswith("limit=")):\n', '    if False:\n',
             "test_start_requires_complete_fixed_head", "incomplete head forged identity"),
            ("identity", "    if observed != start:\n", "    if False:\n",
             "test_owner_pid_reuse_retires_and_audits_once", "different process identity reserved capacity"),
            ("eperm-dead", 'return (True, "process-exists") if strict else True',
             'return (False, "permission-denied") if strict else True',
             "test_owner_eperm_matching_retains_reservation", "EPERM matching identity lost reservation"),
            ("unknown", 'return None, "start-unreadable"', 'return False, "start-unreadable"',
             "test_owner_unknown_keeps_record_and_logs_once", "unknown identity must retain reservation"),
            ("lane-bound", "    if time.monotonic() - started_at >= lane_defer_max:\n", "    if False:\n",
             "test_lane_stopped_waiter_bound_and_no_preemption", "stopped older waiter blocked past lane bound"),
            ("hup", '    wait_signals["hup"] = signal.signal(signal.SIGHUP, wait_signal)\n', '    pass\n',
             "test_wait_signals_cleanup_and_exit_codes", "wait signal leaked waiter record"),
        ]
        for name, old, new, case, invariant in mutations:
            with self.subTest(invariant=invariant):
                binary = self.instrument("owner-mutant-" + name, old, new)
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()), "HeavyQueue." + case],
                    env=dict(self.env, WRK_QUEUE_TEST_BIN=str(binary)), capture_output=True,
                    text=True, timeout=60, check=False)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("AssertionError:", result.stderr)
                self.assertIn(invariant, result.stderr)
                self.assertNotIn("ERROR:", result.stderr, "a crash is not assertion RED")

    def test_mutants_break_the_named_invariants(self):
        mutations = [
            ("fifo", 'lane_limit = lane_reserved() if hclass == "lane" else 0',
             'lane_limit = 0', "test_fifo_reserves_only_eligible_slots",
             "younger lane overtook a live older ticket"),
            ("reuse", '            ticket = tuple(record["ticket"])',
             '            pass  # mutant: discard the saved ticket',
             "test_position_reused_within_grace", "original ticket was not reused within grace"),
            ("dead", '        if not alive(pid):\n', '        if False:\n',
             "test_dead_and_mixed_version_records_reserve_nothing",
             "dead or ticketless record reserved a slot"),
        ]
        for name, old, new, case, invariant in mutations:
            with self.subTest(invariant=invariant):
                binary = self.instrument("mutant-" + name, old, new)
                result = subprocess.run(
                    [sys.executable, str(Path(__file__).resolve()), "HeavyQueue." + case],
                    env=dict(self.env, WRK_QUEUE_TEST_BIN=str(binary)),
                    capture_output=True, text=True, timeout=45, check=False)
                self.assertNotEqual(result.returncode, 0, "mutant survived: " + invariant)
                self.assertIn("AssertionError:", result.stderr)
                self.assertIn(invariant, result.stderr)
                self.assertNotIn("ERROR:", result.stderr, "a crash is not assertion RED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
