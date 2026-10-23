"""Position publication/removal races approved in director escalation 00008."""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

import test_wrk_heavy_queue as fixtures


class PositionGuards(unittest.TestCase):
    def setUp(self):
        self.c = fixtures.HeavyQueue()
        self.c.setUp()

    def tearDown(self):
        self.c.tearDown()

    def guard(self, key="A"):
        return self.c.positions / (".guard-" + key.encode("ascii").hex())

    def expired(self):
        path = self.c.position_path("A")
        path.write_text(json.dumps({"key": "A", "ticket": [1, 1], "expiry": 1}))
        return path

    def status_cap_race(self, require_block):
        c = self.c
        c.start("holder")
        path = c.position_path("A")
        path.write_text(json.dumps({"key": "A", "ticket": [1, 1],
                                    "expiry": time.time() + 60}))
        statted, release, ready = [c.base / name for name in
                                  ("status-statted", "status-release", "cap-ready")]
        c.files.append(release)
        save = '    record = {"key": queue_key, "ticket": ticket,\n'
        writer = c.instrument("cap-wrk", save,
            f"    while not os.path.exists({str(statted)!r}): time.sleep(.01)\n"
            f"    open({str(ready)!r}, 'w').close()\n" + save)
        cap = c.spawn("capping-A", key="A", binary=writer, WRK_HEAVY_WAIT_CAP=".4")
        c.queued("capping-A")
        anchor = '        if (current.st_dev, current.st_ino) == (st.st_dev, st.st_ino):\n'
        status_bin = c.instrument("status-wrk", anchor,
            f"        open({str(statted)!r}, 'w').close()\n"
            f"        while not os.path.exists({str(release)!r}): time.sleep(.01)\n" + anchor)
        text = status_bin.read_text()
        status_bin.write_text(text.replace('if args[0] == "status":\n',
            'if args[0] == "status":\n' +
            f"    time.time = lambda: {time.time() + 120!r}\n", 1))
        out = (c.base / "status.out").open("w+")
        status = subprocess.Popen([str(status_bin), "heavy", "status"], env=c.env,
                                  stdout=out, stderr=subprocess.STDOUT)
        c.procs.append((status, out))
        c.until(statted.exists, "status never reached post-stat boundary")
        c.until(ready.exists, "real capped writer never reached save_position")
        early = False
        try:
            cap.wait(timeout=.4)
            early = True
        except subprocess.TimeoutExpired:
            pass
        finally:
            release.touch()
        self.assertEqual(status.wait(timeout=5), 0)
        self.assertEqual(cap.wait(timeout=5), 75)
        if require_block:
            self.assertFalse(early, "position publish overtook status removal")
        self.assertTrue(path.exists(), "status deleted the fresh cap position after its inode check")
        record = json.loads(path.read_text())
        self.assertEqual(record["ticket"], [1, 1])
        self.assertGreater(record["expiry"], time.time())

    def test_status_preserves_real_cap_after_post_stat_cleanup(self):
        self.status_cap_race(False)

    def test_cap_publish_waits_for_cleanup(self):
        self.status_cap_race(True)

    def test_status_skips_busy_owned_guard(self):
        c = self.c
        path = self.expired()
        guard = self.guard()
        guard.touch(mode=0o600)
        entered = c.base / "status-lock-entered"
        anchor = "def position_guard_lock(fd, *, blocking=True):\n"
        binary = c.instrument("busy-status-wrk", anchor,
                              anchor + f"    open({str(entered)!r}, 'w').close()\n")
        out = (c.base / "busy-status.out").open("w+")
        with guard.open("r+") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            proc = subprocess.Popen([str(binary), "heavy", "status"], env=c.env,
                                    stdout=out, stderr=subprocess.STDOUT)
            c.procs.append((proc, out))
            blocked = False
            try:
                c.until(entered.exists, "status never reached its guard attempt")
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                blocked = True
            finally:
                fcntl.flock(held, fcntl.LOCK_UN)
            self.assertEqual(proc.wait(timeout=5), 0)
        self.assertFalse(blocked, "status waited on a busy position guard")
        self.assertTrue(path.exists(), "busy status cleanup removed a guarded position")

    def test_unsafe_guard_files_fail_closed_without_waiting(self):
        c = self.c
        guard = self.guard()
        target = c.base / "target"
        target.write_text("untouched")
        makers = [lambda: guard.symlink_to(target), lambda: os.mkfifo(guard),
                  lambda: os.link(target, guard),
                  lambda: (guard.touch(), guard.chmod(0o644))]
        for make in makers:
            with self.subTest(make=make):
                make()
                self.expired()
                result = c.run_wrk("--queue-key", "A", "--", "true")
                self.assertEqual(result.returncode, 78, "unsafe guard allowed a keyed run")
                self.assertEqual(c.run_wrk("status").returncode, 0)
                self.assertTrue(c.position_path("A").exists())
                self.assertEqual(target.read_text(), "untouched")
                guard.unlink()

    def test_foreign_owned_guard_is_refused(self):
        c = self.c
        guard = self.guard()
        guard.touch(mode=0o600)
        inode = guard.stat().st_ino
        anchor = 'if args[0] == "status":\n'
        injected = ("import types\n_real_guard_fstat = os.fstat\n"
                    "def _foreign_guard_fstat(fd):\n"
                    "    st = _real_guard_fstat(fd)\n"
                    f"    if st.st_ino == {inode}:\n"
                    "        return types.SimpleNamespace(st_mode=st.st_mode, st_nlink=st.st_nlink,\n"
                    "            st_uid=st.st_uid+1, st_ino=st.st_ino, st_dev=st.st_dev, st_size=st.st_size)\n"
                    "    return st\nos.fstat = _foreign_guard_fstat\n")
        binary = c.instrument("foreign-guard-wrk", anchor, injected + anchor)
        self.expired()
        self.assertEqual(c.run_wrk("--queue-key", "A", "--", "true", binary=binary).returncode, 78)
        self.assertEqual(c.run_wrk("status", binary=binary).returncode, 0)
        self.assertTrue(c.position_path("A").exists())

    def test_concurrent_guard_creation_reopens_and_checks_the_inode(self):
        c = self.c
        target = c.base / "creation-target"
        target.write_text("untouched")
        # The macOS two-process reproduction returned ENOENT from O_CREAT
        # while its peer successfully created this guard. Reproduce that
        # kernel result at the real open call, then require checked reuse.
        for kind, want in (("regular", 0), ("symlink", 78), ("fifo", 78),
                           ("hardlink", 78), ("public", 78), ("missing", 78)):
            with self.subTest(kind=kind):
                guard = self.guard()
                anchor = 'if args[0] == "status":\n'
                injection = ("_guard_real_open = os.open\n_guard_raced = False\n"
                    "def _guard_racing_open(path, flags, mode=0o777, *, dir_fd=None):\n"
                    "    global _guard_raced\n"
                    f"    if path == {guard.name!r} and flags & os.O_CREAT and not _guard_raced:\n"
                    "        _guard_raced = True\n"
                    f"        kind = {kind!r}\n"
                    "        if kind == 'missing': pass\n"
                    "        elif kind == 'symlink':\n"
                    f"            os.symlink({str(target)!r}, path, dir_fd=dir_fd)\n"
                    "        elif kind == 'fifo': os.mkfifo(path, dir_fd=dir_fd)\n"
                    "        elif kind == 'hardlink':\n"
                    f"            os.link({str(target)!r}, path, dst_dir_fd=dir_fd)\n"
                    "        else:\n"
                    "            fd = _guard_real_open(path, flags | os.O_EXCL,\n"
                    "                0o644 if kind == 'public' else mode, dir_fd=dir_fd)\n"
                    "            if kind == 'public': os.fchmod(fd, 0o644)\n"
                    "            os.close(fd)\n"
                    "        raise FileNotFoundError(2, 'concurrent guard creation', path)\n"
                    "    return _guard_real_open(path, flags, mode, dir_fd=dir_fd)\n"
                    "os.open = _guard_racing_open\n")
                binary = c.instrument("create-race-" + kind, anchor, injection + anchor)
                try:
                    result = c.run_wrk("--queue-key", "A", "--", "true", binary=binary)
                    self.assertEqual(result.returncode, want,
                        "concurrent creation must reopen and validate the existing guard: " + result.stderr)
                    self.assertEqual(target.read_text(), "untouched")
                finally:
                    guard.unlink(missing_ok=True)

    def test_dead_guard_holder_releases_and_acquisition_consumes(self):
        c = self.c
        guard = self.guard()
        ready, release = c.base / "guard-ready", c.base / "guard-release"
        c.files.append(release)
        path = c.position_path("A")
        path.write_text(json.dumps({"key": "A", "ticket": [1, 1], "expiry": time.time() + 600}))
        helper = c.base / "guard-holder.py"
        helper.write_text("import fcntl, os, pathlib, sys, threading\n"
            "guard, ready, release = map(pathlib.Path, sys.argv[1:])\n"
            "fd = os.open(guard, os.O_RDWR | os.O_CREAT, 0o600)\n"
            "fcntl.flock(fd, fcntl.LOCK_EX)\nready.touch()\n"
            "while not release.exists(): threading.Event().wait(.02)\n"
            "os._exit(7)\n")
        out = (c.base / "guard-holder.out").open("w+")
        held = subprocess.Popen([sys.executable, str(helper), str(guard), str(ready), str(release)],
                                env=c.env, stdout=out, stderr=subprocess.STDOUT)
        c.procs.append((held, out))
        c.until(ready.exists, "guard holder never became ready")
        acquirer = c.spawn("after-death", key="A")
        c.queued("after-death")
        self.assertFalse(c.started("after-death"))
        release.touch()
        self.assertEqual(held.wait(timeout=5), 7)
        c.until(lambda: c.started("after-death"), "dead guard holder stalled acquisition")
        self.assertFalse(path.exists(), "acquisition did not consume its guarded position")
        c.release("after-death")
        self.assertEqual(acquirer.wait(timeout=5), 0)

    def test_mutants_break_position_guard_invariants(self):
        mutations = [
            ("remove", "        if not position_guard_lock(guardfd, blocking=blocking):\n",
             "        if False:\n", "test_status_preserves_real_cap_after_post_stat_cleanup",
             "status deleted the fresh cap position after its inode check"),
            ("blocking-status", 'remove_position(pfd, name, st, key=record["key"], blocking=False)',
             'remove_position(pfd, name, st, key=record["key"], blocking=True)',
             "test_status_skips_busy_owned_guard", "status waited on a busy position guard"),
        ]
        for name, old, new, case, invariant in mutations:
            with self.subTest(invariant=invariant):
                binary = self.c.instrument("mutant-" + name, old, new)
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()),
                                         "PositionGuards." + case],
                    env=dict(self.c.env, WRK_QUEUE_TEST_BIN=str(binary)),
                    capture_output=True, text=True, timeout=45, check=False)
                self.assertNotEqual(result.returncode, 0, "mutant survived: " + invariant)
                self.assertIn("AssertionError:", result.stderr)
                self.assertIn(invariant, result.stderr)
                self.assertNotIn("ERROR:", result.stderr, "a crash is not assertion RED")


if __name__ == "__main__":
    unittest.main(verbosity=2)
