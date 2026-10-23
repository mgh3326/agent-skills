"""hk 1407: real heavy entry-point tests, using only file-controlled fixtures."""

import json
import os
from pathlib import Path
import re
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
                for path in self.positions.iterdir():
                    record = json.loads(path.read_text())
                    record["expiry"] = time.time() - 1
                    path.write_text(json.dumps(record))
        else:
            self.assertEqual(records, [], "unkeyed cap must not save a place")
        b = self.spawn("b", binary=binary)
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
        self.release("holder")
        for name, proc in order:
            self.until(lambda: self.started(name), f"wrong re-queue acquisition order: {name}")
            actual = (self.base / "order").read_text().splitlines()
            self.assertEqual(actual[-1], name)
            if name == "a-new":
                self.assertEqual(self.position_records(), [], "acquisition did not consume the position")
            self.release(name)
            self.assertEqual(proc.wait(timeout=5), 0)

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
        (self.positions / "key-old.json").write_text(json.dumps(
            {"key": "old", "ticket": [1, 1], "expiry": time.time() - 1}))
        self.assertNotIn("key=old", self.run_wrk("status").stdout)
        self.assertFalse((self.positions / "key-old.json").exists())

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
        (self.positions / "key-link.json").symlink_to(victim)
        os.mkfifo(self.positions / "key-fifo.json")
        (self.positions / "key-bad.json").write_text("not JSON")
        for key in ("link", "fifo", "bad"):
            result = self.run_wrk("--queue-key", key, "--", "true")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(victim.read_text(), "unchanged", "position symlink target changed")
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
