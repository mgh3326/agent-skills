"""hk 1454: the trust-path rule shared by bin/wrk and bin/arbiter.

The decision function is extracted from both sources (they must be
byte-identical) and called with a fake passwd home under a temp dir, so the
non-test-mode path is covered without touching the real home. A tripwire
fails any test that resolves or stats a path under the real passwd home.
"""

import os
import pwd
import re
import shutil
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
BLOCK = re.compile(r"^# >>> trust_paths_decide.*?^# <<< trust_paths_decide$", re.S | re.M)
REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir.rstrip("/")


def shared_block(name):
    blocks = BLOCK.findall((ROOT / "bin" / name).read_text(encoding="utf-8"))
    assert len(blocks) == 1, (name, len(blocks))
    return blocks[0]


namespace = {}
exec(shared_block("wrk"), namespace)
decide = namespace["trust_paths_decide"]


class SharedRule(unittest.TestCase):
    def test_wrk_and_arbiter_carry_the_same_function(self):
        self.assertEqual(shared_block("wrk"), shared_block("arbiter"))


class TrustPaths(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = str(self.tmp / "pw")
        self.inbox = os.path.join(self.home, "work", "herdr-inbox", "jobs")
        self.db = os.path.join(self.home, ".local", "share", "arbiter", "state.db")
        self.hk = os.path.join(self.home, ".local", "bin", "handoffkeep")
        os.makedirs(self.inbox)
        os.makedirs(os.path.dirname(self.hk))
        self.write_exe(self.hk)
        self.uid = os.getuid()
        # Tripwire: no decision may resolve or stat a path under the real home.
        real_realpath, real_stat = os.path.realpath, os.stat

        def guard(path):
            text = os.fspath(path)
            if REAL_HOME and (text == REAL_HOME or text.startswith(REAL_HOME + "/")):
                raise AssertionError("tripwire: test touched the real passwd home: %s" % text)

        def realpath(path, *args, **kwargs):
            guard(path)
            result = real_realpath(path, *args, **kwargs)
            guard(result)
            return result

        def stat_(path, *args, **kwargs):
            guard(path)
            return real_stat(path, *args, **kwargs)

        for target, replacement in (("os.path.realpath", realpath), ("os.stat", stat_)):
            patcher = mock.patch(target, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_exe(self, path, mode=0o755):
        Path(path).write_text("#!/bin/sh\nexit 0\n")
        os.chmod(path, mode)

    def env(self, **extra):
        base = {"HOME": self.home, "PATH": "/usr/bin:/bin", "TMPDIR": str(self.tmp)}
        base.update(extra)
        return {k: v for k, v in base.items() if v is not None}

    def run_decide(self, env, need=("inbox", "db", "handoffkeep"), fixtures=""):
        return decide(env, self.home, self.uid, fixtures, set(need))

    # ── outside test mode ─────────────────────────────────────────────────
    def test_canonical_paths_accepted(self):
        result = self.run_decide(self.env())
        self.assertEqual(result["error"], "")
        self.assertEqual(result["warning"], "")
        self.assertEqual(result["inbox"], self.inbox)
        self.assertEqual(result["db"], self.db)
        self.assertEqual(result["handoffkeep"], os.path.realpath(self.hk))

    def test_inbox_redirect_refused_naming_variable_and_canonical(self):
        result = self.run_decide(self.env(ARBITER_INBOX_ROOT=str(self.tmp / "builder")), need=("inbox",))
        self.assertIn("ARBITER_INBOX_ROOT", result["error"])
        self.assertIn(self.inbox, result["error"])

    def test_data_home_and_home_redirects_refused(self):
        result = self.run_decide(self.env(XDG_DATA_HOME=str(self.tmp / "d")), need=("db",))
        self.assertTrue(result["error"].startswith("XDG_DATA_HOME "), result)
        self.assertIn(self.db, result["error"])
        result = self.run_decide(self.env(HOME=str(self.tmp / "other")), need=("inbox",))
        self.assertTrue(result["error"].startswith("HOME "), result)

    def test_canonical_spellings_accepted(self):
        os.symlink(os.path.join(self.home, "work"), self.tmp / "link")
        for value in (self.inbox + "/", str(self.tmp / "link" / "herdr-inbox" / "jobs"),
                      os.path.join(self.home, "work", "..", "work", "herdr-inbox", "jobs")):
            result = self.run_decide(self.env(ARBITER_INBOX_ROOT=value), need=("inbox",))
            self.assertEqual(result["error"], "", value)
            self.assertEqual(result["inbox"], value)
        result = self.run_decide(self.env(HANDOFFKEEP_BIN=self.hk), need=("handoffkeep",))
        self.assertEqual(result["error"], "")

    def test_handoffkeep_bin_stub_refused(self):
        stub = str(self.tmp / "stub")
        self.write_exe(stub)
        result = self.run_decide(self.env(HANDOFFKEEP_BIN=stub), need=("handoffkeep",))
        self.assertIn("HANDOFFKEEP_BIN", result["error"])
        self.assertIn(self.hk, result["error"])

    def test_path_shim_ignored_outside_test_mode(self):
        shim = self.tmp / "shim"
        shim.mkdir()
        self.write_exe(shim / "handoffkeep")
        result = self.run_decide(self.env(PATH=str(shim)), need=("handoffkeep",))
        self.assertEqual(result["error"], "")
        self.assertEqual(result["handoffkeep"], os.path.realpath(self.hk))

    def test_insecure_canonical_handoffkeep_refused(self):
        for mode in (0o775, 0o757, 0o644):
            os.chmod(self.hk, mode)
            result = self.run_decide(self.env(), need=("handoffkeep",))
            self.assertIn("canonical handoffkeep", result["error"], oct(mode))
        os.unlink(self.hk)
        self.assertIn("missing", self.run_decide(self.env(), need=("handoffkeep",))["error"])
        os.mkdir(self.hk)
        self.assertIn("not a regular", self.run_decide(self.env(), need=("handoffkeep",))["error"])
        os.rmdir(self.hk)
        self.write_exe(self.hk)
        # A file owned by another uid (seen through a symlink or not) is foreign.
        result = decide(self.env(), self.home, self.uid + 1, "", {"handoffkeep"})
        self.assertIn("not a regular executable owned by uid", result["error"])
        foreign = next(p for p in ("/bin/sh", "/usr/bin/env", "/bin/ls") if os.stat(p).st_uid != self.uid)
        os.unlink(self.hk)
        os.symlink(foreign, self.hk)
        self.assertIn("owned by uid", self.run_decide(self.env(), need=("handoffkeep",))["error"])

    def test_newline_refused(self):
        result = self.run_decide(self.env(ARBITER_INBOX_ROOT=self.inbox + "\nx"), need=("inbox",))
        self.assertIn("newline", result["error"])

    # ── test mode ─────────────────────────────────────────────────────────
    def test_mode_temp_overrides_honoured_with_one_warning(self):
        stub = str(self.tmp / "stub")
        self.write_exe(stub)
        env = self.env(WRK_TEST_MODE="1", ARBITER_INBOX_ROOT=str(self.tmp / "i"),
                       XDG_DATA_HOME=str(self.tmp / "d"), HANDOFFKEEP_BIN=stub)
        result = self.run_decide(env)
        self.assertEqual(result["error"], "")
        self.assertEqual(result["inbox"], str(self.tmp / "i"))
        self.assertEqual(result["handoffkeep"], stub)
        self.assertEqual(result["warning"],
                         "WRK_TEST_MODE=1: trust paths taken from ARBITER_INBOX_ROOT HANDOFFKEEP_BIN XDG_DATA_HOME")

    def test_mode_override_outside_temp_roots_refused(self):
        for value in ("/nonexistent-wrk-1454/jobs", "/tmp/../nonexistent-wrk-1454", "/tmp", "/"):
            result = self.run_decide(self.env(WRK_TEST_MODE="1", ARBITER_INBOX_ROOT=value), need=("inbox",))
            self.assertIn("outside the test temp roots", result["error"], value)
        os.symlink("/usr", self.tmp / "escape")
        result = self.run_decide(self.env(WRK_TEST_MODE="1", HANDOFFKEEP_BIN=str(self.tmp / "escape" / "bin" / "env")),
                                 need=("handoffkeep",))
        self.assertIn("HANDOFFKEEP_BIN resolves outside", result["error"])

    def test_mode_tripwire_on_the_passwd_home(self):
        # The fake passwd home lies under TMPDIR here; resolving into it is
        # still refused, directly or through a symlink.
        os.symlink(self.home, self.tmp / "to-home")
        for value in (self.inbox, str(self.tmp / "to-home" / "work" / "herdr-inbox" / "jobs")):
            result = self.run_decide(self.env(WRK_TEST_MODE="1", ARBITER_INBOX_ROOT=value), need=("inbox",))
            self.assertIn("tripwire", result["error"], value)
        # Unset overrides fall back to HOME, which here is the passwd home.
        result = self.run_decide(self.env(WRK_TEST_MODE="1"), need=("inbox",))
        self.assertIn("tripwire: HOME", result["error"])

    def test_mode_tmpdir_at_or_above_the_home_is_not_a_temp_root(self):
        outside = "/nonexistent-wrk-1454"
        home = outside + "/home/u"
        for tmpdir in (home, outside, outside + "/home/u/tmp"):
            env = {"WRK_TEST_MODE": "1", "TMPDIR": tmpdir, "HOME": home,
                   "ARBITER_INBOX_ROOT": outside + "/x/jobs"}
            result = decide(env, home, self.uid, "", {"inbox"})
            self.assertNotEqual(result["error"], "", tmpdir)

    def test_mode_missing_handoffkeep_is_empty_not_canonical(self):
        result = self.run_decide(self.env(WRK_TEST_MODE="1", PATH=str(self.tmp / "nobin"),
                                          ARBITER_INBOX_ROOT=str(self.tmp / "i")),
                                 need=("inbox", "handoffkeep"))
        self.assertEqual(result["error"], "")
        self.assertEqual(result["handoffkeep"], "")


if __name__ == "__main__":
    unittest.main()
