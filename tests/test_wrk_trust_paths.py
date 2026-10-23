"""hk 1894: trust-bearing operations read their inbox, arbiter DB and handoffkeep
only from the passwd home of the current uid.

Three layers, each hermetic:

* the decision function, in both implementations (the block embedded in bin/wrk
  and the one in bin/arbiter), with the canonical home passed in as an argument
  and a tripwire that fails if anything resolves under the real passwd home;
* the real bin/wrk and bin/arbiter, run outside WRK_TEST_MODE against a fake
  passwd home (tests/fixtures/trust-home/sitecustomize.py answers it) with the
  same tripwire armed in every child python;
* mutants applied at the real call sites: each invariant must go RED.
"""
import contextlib
import hashlib
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
WRK = ROOT / "bin" / "wrk"
ARBITER = ROOT / "bin" / "arbiter"
HOOK = ROOT / "tests" / "fixtures" / "trust-home"
sys.path.insert(0, str(ROOT / "tests" / "lib"))
import trust_tripwire  # noqa: E402

BEGIN = "# --- trust paths: begin"
END = "# --- trust paths: end ---"
OUTSIDE = "/usr/lib/trust-test-outside"
REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir
# What a trust-bearing operation did before hk 1894, as a replacement for the guard call.
ENV_FOLLOWING = '  WRK_TRUST_JOBS_ROOT="$(wrk_jobs_root)"\n'
ENV_FOLLOWING_HK = '  WRK_TRUST_JOBS_ROOT="$(wrk_jobs_root)" WRK_TRUST_HK="$(hk_bin)"\n'


def trust_block(text):
    lines = text.splitlines()
    first = next(i for i, line in enumerate(lines) if line.startswith(BEGIN))
    last = next(i for i, line in enumerate(lines) if line == END)
    return "\n".join(lines[first:last + 1]) + "\n"


def wrk_python(text):
    match = re.search(r"^WRK_TRUST_PY='\n(.*?)^'$", text, re.S | re.M)
    if match is None:
        raise AssertionError("bin/wrk has no WRK_TRUST_PY block")
    return match.group(1)


def mutate(text, old, new):
    if text.count(old) != 1:
        raise AssertionError("mutant anchor must occur exactly once (found %d): %r" % (text.count(old), old))
    return text.replace(old, new)


class Impl:
    """One implementation of the decision function, loaded from source text."""

    def __init__(self, name, text=None):
        self.name = name
        source = text if text is not None else (WRK if name == "wrk" else ARBITER).read_text(encoding="utf-8")
        self.source = source
        self.ns = {"__name__": name + "_trust_under_test"}
        code = wrk_python(source) if name == "wrk" else source
        exec(compile(code, "bin/" + name, "exec"), self.ns)

    def resolve(self, *args, **kwargs):
        return self.ns["trust_resolve"](*args, **kwargs)

    @property
    def Refusal(self):
        return self.ns["TrustRefusal"]

    @contextlib.contextmanager
    def system_roots(self, roots):
        saved = self.ns["TRUST_SYSTEM_TEMP_ROOTS"]
        self.ns["TRUST_SYSTEM_TEMP_ROOTS"] = tuple(roots)
        try:
            yield
        finally:
            self.ns["TRUST_SYSTEM_TEMP_ROOTS"] = saved


def both(mutation=None):
    """The wrk and arbiter implementations, optionally with one mutation applied to both."""
    result = []
    for name, path in (("wrk", WRK), ("arbiter", ARBITER)):
        text = path.read_text(encoding="utf-8")
        if mutation is not None:
            text = mutate(text, *mutation)
        result.append(Impl(name, text))
    return result


def safe_path():
    """PATH without the real passwd home's ~/.local/bin, so no run can reach the
    real handoffkeep (or any other tool installed there) by a PATH lookup."""
    root = os.path.join(REAL_HOME, ".local", "bin")
    keep = []
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        normal = os.path.normpath(os.path.abspath(entry)) if entry else ""
        if entry and normal != root and not normal.startswith(root + os.sep):
            keep.append(entry)
    return os.pathsep.join(keep)


def write_exec(path, body="#!/bin/sh\nexit 0\n", mode=0o755):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    path.chmod(mode)


# ---------------------------------------------------------------------------
# 1. the decision function


class DecisionCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        trust_tripwire.install()

    @classmethod
    def tearDownClass(cls):
        tripped = trust_tripwire.trips()
        trust_tripwire.uninstall()
        assert not tripped, tripped

    def setUp(self):
        self.impls = both()
        self.build_world()

    def build_world(self):
        """A fresh canonical home and temp root; every check starts from one."""
        self.base = Path(os.path.realpath(tempfile.mkdtemp(prefix="trust-unit-")))
        self.addCleanup(shutil.rmtree, self.base, True)
        self.home = self.base / "home"
        self.inbox = self.home / "work" / "herdr-inbox" / "jobs"
        self.inbox.mkdir(parents=True)
        self.dbdir = self.home / ".local" / "share" / "arbiter"
        self.dbdir.mkdir(parents=True)
        self.db = self.dbdir / "state.db"
        self.hk = self.home / ".local" / "bin" / "handoffkeep"
        write_exec(self.hk)
        self.other = self.base / "other"
        self.other.mkdir()
        self.tmp = self.base / "tmp"
        self.tmp.mkdir()
        self.uid = os.getuid()

    def env(self, **extra):
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin"}
        for key, value in extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        return env

    def resolve(self, impl, env, test_mode=False, need_hk=False, fixtures="", uid=None, home=None):
        return impl.resolve(env, str(self.home) if home is None else home,
                            self.uid if uid is None else uid, test_mode, need_hk, fixtures)

    def refused(self, impl, env, var, label="", **kwargs):
        try:
            result = self.resolve(impl, env, **kwargs)
        except impl.Refusal as exc:
            self.assertEqual(exc.var, var, "%s: %s" % (label, exc))
            return exc
        self.fail("%s: not refused (expected a refusal naming %s, got %r)" % (label, var, result))

    def temp_env(self, **extra):
        """Test-mode environment whose overrides all live under TMPDIR=self.tmp."""
        env = self.env(TMPDIR=self.tmp, HOME=self.tmp / "home",
                       ARBITER_INBOX_ROOT=self.tmp / "inbox", XDG_DATA_HOME=self.tmp / "data",
                       HANDOFFKEEP_BIN=self.tmp / "hk")
        for key, value in extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        return env

    # -- checks shared by the real run and the mutants (each takes one Impl) --

    def check_canonical_accepted(self, impl):
        out = self.resolve(impl, self.env(), need_hk=True)
        self.assertEqual(out["inbox"], str(self.inbox))
        self.assertEqual(out["db"], str(self.db))
        self.assertEqual(out["hk"], str(self.hk))
        self.assertEqual(out["overrides"], [])
        # HOME unset falls back to the passwd home, as arbiter.inbox_root() does.
        out = self.resolve(impl, self.env(HOME=None), need_hk=True)
        self.assertEqual(out["inbox"], str(self.inbox))

    def check_inbox_redirect(self, impl):
        exc = self.refused(impl, self.env(ARBITER_INBOX_ROOT=self.other), "ARBITER_INBOX_ROOT")
        self.assertEqual(exc.canonical, str(self.inbox))
        self.assertIn(str(self.inbox), str(exc))
        self.assertIn("ARBITER_INBOX_ROOT", str(exc))

    def check_data_home_redirect(self, impl):
        exc = self.refused(impl, self.env(XDG_DATA_HOME=self.other), "XDG_DATA_HOME")
        self.assertEqual(exc.canonical, str(self.db))
        self.assertIn(str(self.db), str(exc))

    def check_home_redirect(self, impl):
        exc = self.refused(impl, self.env(HOME=self.other), "HOME")
        self.assertEqual(exc.canonical, str(self.home))
        # HOME alone, with no explicit lever, also moves both defaults.
        self.refused(impl, self.env(HOME=self.other, ARBITER_INBOX_ROOT=self.inbox), "HOME")

    def check_hk_env_redirect(self, impl):
        stub = self.other / "forge-hk"
        write_exec(stub)
        exc = self.refused(impl, self.env(HANDOFFKEEP_BIN=stub), "HANDOFFKEEP_BIN", need_hk=True)
        self.assertEqual(exc.canonical, str(self.hk))
        self.assertIn(str(self.hk), str(exc))

    def check_hk_judged_where_used(self, impl):
        stub = self.other / "forge-hk"
        write_exec(stub)
        out = self.resolve(impl, self.env(HANDOFFKEEP_BIN=stub), need_hk=False)
        self.assertEqual(out["hk"], "")

    def check_path_shim_ignored(self, impl):
        shim = self.other / "shim"
        write_exec(shim / "handoffkeep")
        out = self.resolve(impl, self.env(PATH="%s:/usr/bin:/bin" % shim), need_hk=True)
        self.assertEqual(out["hk"], str(self.hk))
        self.assertNotIn(str(shim), json.dumps(out))
        # A bare HANDOFFKEEP_BIN that PATH resolves to the shim is an override, not a lookup.
        self.refused(impl, self.env(HANDOFFKEEP_BIN="handoffkeep", PATH="%s:/usr/bin:/bin" % shim),
                     "HANDOFFKEEP_BIN", need_hk=True)

    def check_equal_forms_accepted(self, impl):
        link = self.base / "link"
        link.symlink_to(self.home)
        forms = {
            "trailing slash": dict(ARBITER_INBOX_ROOT=str(self.inbox) + "/"),
            "double slash": dict(ARBITER_INBOX_ROOT=str(self.inbox) + "//"),
            "dot segment": dict(ARBITER_INBOX_ROOT=str(self.inbox) + "/."),
            "dotdot segment": dict(ARBITER_INBOX_ROOT=str(self.inbox) + "/../jobs"),
            "symlinked parent": dict(ARBITER_INBOX_ROOT="%s/work/herdr-inbox/jobs" % link),
            "data home": dict(XDG_DATA_HOME=str(self.home / ".local" / "share") + "/"),
            "symlinked data home": dict(XDG_DATA_HOME="%s/.local/share" % link),
            "symlinked HOME": dict(HOME=link),
            "trailing-slash HOME": dict(HOME=str(self.home) + "/"),
        }
        for label, extra in forms.items():
            out = self.resolve(impl, self.env(**extra), need_hk=True)
            self.assertEqual((out["inbox"], out["db"], out["overrides"]),
                             (str(self.inbox), str(self.db), []), label)
        hk_link = self.base / "hk-link"
        hk_link.symlink_to(self.hk)
        for label, extra in {"canonical path": dict(HANDOFFKEEP_BIN=self.hk),
                             "symlink to it": dict(HANDOFFKEEP_BIN=hk_link),
                             "bare name on PATH": dict(HANDOFFKEEP_BIN="handoffkeep",
                                                       PATH="%s:/usr/bin" % self.hk.parent)}.items():
            self.assertEqual(self.resolve(impl, self.env(**extra), need_hk=True)["hk"], str(self.hk), label)
        # The canonical location may itself be a symlink; its target is the same place.
        real = self.base / "real-jobs"
        self.inbox.rmdir()
        real.mkdir()
        self.inbox.symlink_to(real)
        for value in (self.inbox, real):
            self.assertEqual(self.resolve(impl, self.env(ARBITER_INBOX_ROOT=value))["inbox"], str(self.inbox))

    def check_odd_values_refused(self, impl):
        evil = self.base / "evil"
        evil.symlink_to(self.other)
        for label, value in {
            "trailing space": str(self.inbox) + " ",
            "zero-width space": str(self.inbox) + "\u200b",
            "lookalike letter": str(self.inbox).replace("jobs", "j\u043ebs"),
            "subdirectory": str(self.inbox / "sub"),
            "parent": str(self.inbox / ".."),
            "relative": "jobs",
            "symlink to a builder dir": str(evil),
        }.items():
            self.refused(impl, self.env(ARBITER_INBOX_ROOT=value), "ARBITER_INBOX_ROOT", label)
        for label, value in {"newline": str(self.inbox) + "\nx", "tab": str(self.inbox) + "\tx", "NUL-free escape": str(self.inbox) + "\x1b"}.items():
            exc = self.refused(impl, self.env(ARBITER_INBOX_ROOT=value), "ARBITER_INBOX_ROOT", label)
            self.assertIn("control character", str(exc), label)

    def check_insecure_hk_refused(self, impl):
        for label, mode in {"group-writable": 0o775, "world-writable": 0o757, "group+world": 0o777}.items():
            self.hk.chmod(mode)
            exc = self.refused(impl, self.env(), "handoffkeep", label, need_hk=True)
            self.assertIn("writable", str(exc), label)
            self.assertIn(str(self.hk), str(exc), label)
        for mode in (0o755, 0o750, 0o700, 0o644):
            self.hk.chmod(mode)
            self.assertEqual(self.resolve(impl, self.env(), need_hk=True)["hk"], str(self.hk), oct(mode))
        self.hk.chmod(0o755)
        # owned by someone else: the file is ours, the caller says the uid is not
        exc = self.refused(impl, self.env(), "handoffkeep", need_hk=True, uid=self.uid + 1)
        self.assertIn("owned by uid", str(exc))
        target = self.base / "elsewhere" / "handoffkeep"
        write_exec(target)
        self.hk.unlink()
        self.hk.symlink_to(target)
        self.assertEqual(self.resolve(impl, self.env(), need_hk=True)["hk"], str(target))
        exc = self.refused(impl, self.env(), "handoffkeep", need_hk=True, uid=self.uid + 1)
        self.assertIn(str(target), str(exc))
        target.chmod(0o775)
        self.refused(impl, self.env(), "handoffkeep", need_hk=True)
        self.hk.unlink()
        self.refused(impl, self.env(), "handoffkeep", need_hk=True)
        self.hk.mkdir()
        exc = self.refused(impl, self.env(), "handoffkeep", need_hk=True)
        self.assertIn("regular file", str(exc))
        self.hk.rmdir()
        self.hk.symlink_to(self.hk)
        self.refused(impl, self.env(), "handoffkeep", need_hk=True)
        # The binary is judged only where it is needed.
        self.assertEqual(self.resolve(impl, self.env(), need_hk=False)["hk"], "")

    def check_home_unknown(self, impl):
        for home in ("", "relative/home"):
            self.refused(impl, self.env(), "HOME", repr(home), home=home)

    def check_test_mode_honours_temp(self, impl):
        with impl.system_roots(()):
            out = self.resolve(impl, self.temp_env(), test_mode=True, need_hk=True)
            self.assertEqual(out["inbox"], str(self.tmp / "inbox"))
            self.assertEqual(out["db"], str(self.tmp / "data" / "arbiter" / "state.db"))
            self.assertEqual(out["hk"], str(self.tmp / "hk"))
            self.assertEqual(out["overrides"], ["ARBITER_INBOX_ROOT", "XDG_DATA_HOME", "HANDOFFKEEP_BIN"])
            # HOME is an override only where it supplies a default.
            out = self.resolve(impl, self.temp_env(ARBITER_INBOX_ROOT=None, XDG_DATA_HOME=None),
                               test_mode=True)
            self.assertEqual(out["inbox"], str(self.tmp / "home" / "work" / "herdr-inbox" / "jobs"))
            self.assertEqual(out["overrides"], ["HOME"])
            out = self.resolve(impl, self.temp_env(XDG_DATA_HOME=None), test_mode=True)
            self.assertEqual(out["overrides"], ["ARBITER_INBOX_ROOT", "HOME"])
            # Spelled through a symlinked TMPDIR or with a dotdot that stays inside: honoured.
            link = self.base / "tlink"
            link.symlink_to(self.tmp)
            out = self.resolve(impl, self.temp_env(TMPDIR=link, ARBITER_INBOX_ROOT="%s/x/../inbox" % link),
                               test_mode=True)
            self.assertEqual(out["inbox"], "%s/x/../inbox" % link)

    def check_test_mode_outside_refused(self, impl):
        with impl.system_roots(()):
            for var, key in (("ARBITER_INBOX_ROOT", "ARBITER_INBOX_ROOT"), ("XDG_DATA_HOME", "XDG_DATA_HOME"),
                             ("HOME", "HOME"), ("HANDOFFKEEP_BIN", "HANDOFFKEEP_BIN")):
                extra = {key: OUTSIDE + "/x"}
                if var == "HOME":
                    extra.update(ARBITER_INBOX_ROOT=None, XDG_DATA_HOME=None)
                exc = self.refused(impl, self.temp_env(**extra), var, var, test_mode=True, need_hk=True)
                self.assertIn("outside the temp roots", str(exc), var)
                self.assertIn(var, str(exc), var)
                self.assertIn("canonical path", str(exc), var)
            self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT="%s/../other" % self.tmp),
                         "ARBITER_INBOX_ROOT", test_mode=True)
            (self.tmp / "esc").symlink_to("/usr/lib")
            self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT=self.tmp / "esc" / "x"),
                         "ARBITER_INBOX_ROOT", test_mode=True)
        # Only the temp roots of the brief exist; /usr/lib is none of them.
        self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT=OUTSIDE), "ARBITER_INBOX_ROOT", test_mode=True)

    def check_test_mode_fixtures_only_for_hk(self, impl):
        fixtures = self.other / "fixtures"
        write_exec(fixtures / "handoffkeep")
        with impl.system_roots(()):
            env = self.temp_env(HANDOFFKEEP_BIN=fixtures / "handoffkeep")
            out = self.resolve(impl, env, test_mode=True, need_hk=True, fixtures=str(fixtures))
            self.assertEqual(out["hk"], str(fixtures / "handoffkeep"))
            self.refused(impl, env, "HANDOFFKEEP_BIN", test_mode=True, need_hk=True)
            self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT=fixtures / "inbox"), "ARBITER_INBOX_ROOT",
                         test_mode=True, fixtures=str(fixtures))

    def check_test_mode_never_canonical(self, impl):
        with impl.system_roots(()):
            # The canonical path is not an override and test mode never uses it.
            self.refused(impl, self.temp_env(XDG_DATA_HOME=None, HOME=self.home), "HOME", test_mode=True)
            self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT=self.inbox), "ARBITER_INBOX_ROOT", test_mode=True)
            self.refused(impl, self.temp_env(HANDOFFKEEP_BIN=self.hk), "HANDOFFKEEP_BIN",
                         test_mode=True, need_hk=True)
            exc = self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT=None, XDG_DATA_HOME=None, HOME=None),
                               "HOME", test_mode=True)
            self.assertIn("test mode never uses", str(exc))
        # And with the real passwd home as the canonical home (the tripwire is armed)
        # nothing under it is resolved: overrides under TMPDIR decide on their own.
        with impl.system_roots(()):
            out = self.resolve(impl, self.temp_env(), test_mode=True, need_hk=True, home=REAL_HOME)
            self.assertEqual(out["inbox"], str(self.tmp / "inbox"))
            self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT=None, XDG_DATA_HOME=None, HOME=None),
                         "HOME", test_mode=True, home=REAL_HOME)

    def check_test_mode_path_shim(self, impl):
        shim = self.tmp / "shim"
        write_exec(shim / "handoffkeep")
        with impl.system_roots(()):
            env = self.temp_env(HANDOFFKEEP_BIN=None, PATH="%s:/usr/bin:/bin" % shim)
            out = self.resolve(impl, env, test_mode=True, need_hk=True)
            self.assertEqual(out["hk"], str(shim / "handoffkeep"))
            self.assertIn("PATH", out["overrides"])
            # nothing on PATH: unavailable, not an error
            out = self.resolve(impl, self.temp_env(HANDOFFKEEP_BIN=None, PATH="/nonexistent-bin"),
                               test_mode=True, need_hk=True)
            self.assertEqual(out["hk"], "")
            # a bare HANDOFFKEEP_BIN resolves through PATH; an absent path is passed through
            out = self.resolve(impl, self.temp_env(HANDOFFKEEP_BIN="handoffkeep", PATH="%s:/usr/bin" % shim),
                               test_mode=True, need_hk=True)
            self.assertEqual(out["hk"], str(shim / "handoffkeep"))
            out = self.resolve(impl, self.temp_env(HANDOFFKEEP_BIN=self.tmp / "absent-hk"),
                               test_mode=True, need_hk=True)
            self.assertEqual(out["hk"], str(self.tmp / "absent-hk"))
            # a handoffkeep found on PATH outside every temp root is refused, never used
            write_exec(self.other / "pathbin" / "handoffkeep")
            self.refused(impl, self.temp_env(HANDOFFKEEP_BIN=None, PATH="%s:/usr/bin" % (self.other / "pathbin")),
                         "PATH", test_mode=True, need_hk=True)

    def check_test_mode_tmpdir_guards(self, impl):
        with impl.system_roots(()):
            for label, tmpdir in {"the canonical home": self.home, "a parent of it": self.base,
                                  "filesystem root": "/"}.items():
                target = (self.home / "x") if tmpdir == self.home else (
                    self.tmp / "inbox" if tmpdir == self.base else Path(OUTSIDE) / "x")
                self.refused(impl, self.temp_env(TMPDIR=tmpdir, ARBITER_INBOX_ROOT=target),
                             "ARBITER_INBOX_ROOT", "TMPDIR is " + label, test_mode=True)
            # a TMPDIR below the home is an ordinary temp root
            below = self.home / "scratch"
            below.mkdir()
            out = self.resolve(impl, self.temp_env(TMPDIR=below, ARBITER_INBOX_ROOT=below / "inbox",
                                                   XDG_DATA_HOME=below / "data"), test_mode=True)
            self.assertEqual(out["inbox"], str(below / "inbox"))
        seen = {"/var/folders": "/private/var/folders", "/tmp": "/tmp", "/private/tmp": "/private/tmp"}
        real = os.path.realpath

        def fake(path, *args, **kwargs):
            return seen.get(path, real(path, *args, **kwargs))

        with mock.patch("os.path.realpath", fake):
            roots = impl.ns["trust_temp_roots"]({}, str(self.home))
        for expected in ("/tmp", "/private/tmp", "/var/folders", "/private/var/folders"):
            self.assertIn(expected, roots)

    def check_test_mode_control_chars(self, impl):
        with impl.system_roots(()):
            exc = self.refused(impl, self.temp_env(ARBITER_INBOX_ROOT="%s/a\nb" % self.tmp),
                               "ARBITER_INBOX_ROOT", test_mode=True)
            self.assertIn("control character", str(exc))

    # -- the tests --

    def each(self, check):
        for impl in self.impls:
            with self.subTest(impl=impl.name):
                self.build_world()
                check(impl)

    def test_canonical_paths_are_accepted(self):
        self.each(self.check_canonical_accepted)

    def test_env_inbox_root_redirect_is_refused(self):
        self.each(self.check_inbox_redirect)

    def test_env_data_home_redirect_is_refused(self):
        self.each(self.check_data_home_redirect)

    def test_home_redirect_is_refused(self):
        self.each(self.check_home_redirect)

    def test_handoffkeep_bin_redirect_is_refused(self):
        self.each(self.check_hk_env_redirect)

    def test_handoffkeep_is_judged_where_it_is_used(self):
        self.each(self.check_hk_judged_where_used)

    def test_path_handoffkeep_is_never_used(self):
        self.each(self.check_path_shim_ignored)

    def test_values_equal_to_the_canonical_path_are_accepted(self):
        self.each(self.check_equal_forms_accepted)

    def test_odd_spellings_of_other_paths_are_refused(self):
        self.each(self.check_odd_values_refused)

    def test_insecure_canonical_handoffkeep_is_refused(self):
        self.each(self.check_insecure_hk_refused)

    def test_unknown_passwd_home_is_refused(self):
        self.each(self.check_home_unknown)

    def test_test_mode_honours_overrides_under_temp_roots(self):
        self.each(self.check_test_mode_honours_temp)

    def test_test_mode_refuses_overrides_outside_temp_roots(self):
        self.each(self.check_test_mode_outside_refused)

    def test_test_mode_fixtures_root_is_for_the_binary_only(self):
        self.each(self.check_test_mode_fixtures_only_for_hk)

    def test_test_mode_never_uses_or_resolves_the_canonical_path(self):
        self.each(self.check_test_mode_never_canonical)

    def test_test_mode_path_lookup_of_handoffkeep(self):
        self.each(self.check_test_mode_path_shim)

    def test_test_mode_tmpdir_that_contains_the_home_is_not_a_root(self):
        self.each(self.check_test_mode_tmpdir_guards)

    def test_test_mode_control_characters_are_refused(self):
        self.each(self.check_test_mode_control_chars)

    def test_one_rule_in_both_implementations(self):
        wrk_block = trust_block(WRK.read_text(encoding="utf-8"))
        arbiter_block = trust_block(ARBITER.read_text(encoding="utf-8"))
        self.assertEqual(wrk_block, arbiter_block)
        self.assertNotIn("'", wrk_block, "the block lives inside a single-quoted bash string")

    # -- mutants of the decision function, one invariant each --

    def red(self, mutation, check):
        for impl in both(mutation):
            with self.subTest(impl=impl.name, mutant=mutation[0][:60]):
                self.assertTrue(impl.source != (WRK if impl.name == "wrk" else ARBITER).read_text(encoding="utf-8"))
                self.build_world()
                with self.assertRaises(Exception):
                    check(impl)

    def test_mutant_test_mode_accepts_a_path_outside_the_temp_roots(self):
        self.red(("        if not any(trust_under(resolved, root) for root in allowed):",
                  "        if False:"), self.check_test_mode_outside_refused)

    def test_mutant_handoffkeep_bin_is_honoured_outside_test_mode(self):
        self.red(('            if hk_env:\n                found = hk_env if "/" in hk_env else (shutil.which(hk_env, path=search) or hk_env)\n'
                  '                judge("HANDOFFKEEP_BIN", found, canon["hk"], "handoffkeep", ())\n'
                  '            hk = trust_secure_binary(canon["hk"], uid)',
                  '            hk = hk_env or trust_secure_binary(canon["hk"], uid)'),
                 self.check_hk_env_redirect)

    def test_mutant_path_lookup_is_used_outside_test_mode(self):
        self.red(('            hk = trust_secure_binary(canon["hk"], uid)',
                  '            hk = shutil.which("handoffkeep", path=search) or trust_secure_binary(canon["hk"], uid)'),
                 self.check_path_shim_ignored)

    def test_mutant_home_is_not_compared(self):
        self.red(('    if home_env and not test_mode:\n        judge("HOME", home_env, home, "home", ())\n',
                  '    if home_env and not test_mode:\n        pass\n'), self.check_home_redirect)

    def test_mutant_inbox_is_compared_with_itself(self):
        self.red(('inbox_env or under_home("work", "herdr-inbox", "jobs"), canon["inbox"], "inbox", roots)',
                  'inbox_env or under_home("work", "herdr-inbox", "jobs"), inbox_env or under_home("work", "herdr-inbox", "jobs"), "inbox", roots)'),
                 self.check_inbox_redirect)

    def test_mutant_data_home_is_compared_with_itself(self):
        self.red(('"arbiter", "state.db"), canon["db"], "arbiter DB", roots)',
                  '"arbiter", "state.db"), os.path.join(data_env or under_home(".local", "share"), "arbiter", "state.db"), "arbiter DB", roots)'),
                 self.check_data_home_redirect)

    def test_mutant_group_and_world_write_are_allowed(self):
        self.red(("    if info.st_mode & 0o022:", "    if False:"), self.check_insecure_hk_refused)

    def test_mutant_foreign_owner_is_allowed(self):
        self.red(("    if info.st_uid != uid:", "    if False:"), self.check_insecure_hk_refused)

    def test_mutant_paths_are_not_resolved(self):
        self.red(("        resolved = os.path.realpath(effective)\n        if not test_mode:",
                  "        resolved = effective\n        if not test_mode:"), self.check_equal_forms_accepted)

    def test_mutant_control_characters_pass(self):
        self.red(("        if any(ord(ch) < 32 or ord(ch) == 127 for ch in effective):",
                  "        if False:"), self.check_test_mode_control_chars)

    def test_mutant_test_mode_uses_the_canonical_path(self):
        self.red(("        resolved = os.path.realpath(effective)\n        if not test_mode:",
                  "        resolved = os.path.realpath(effective)\n        if canonical and resolved == os.path.realpath(canonical):\n            return canonical\n        if not test_mode:"),
                 self.check_test_mode_never_canonical)

    def test_mutant_tmpdir_may_contain_the_home(self):
        self.red(('        if resolved != "/" and not (home and trust_under(home, resolved)):',
                  "        if True:"), self.check_test_mode_tmpdir_guards)


# ---------------------------------------------------------------------------
# 2. the tripwire itself


class TripwireCase(unittest.TestCase):
    def test_in_process_tripwire_trips_before_the_real_call(self):
        trust_tripwire.install()
        try:
            for call in (lambda p: os.lstat(p), lambda p: os.stat(p), lambda p: open(p), lambda p: os.listdir(p),
                         lambda p: os.path.realpath(p), lambda p: os.path.exists(p)):
                for rel in ("work/herdr-inbox/jobs", ".local/share/arbiter/state.db", ".local/bin/handoffkeep"):
                    with self.assertRaises(AssertionError):
                        call(os.path.join(REAL_HOME, rel))
            self.assertEqual(len(trust_tripwire.trips()), 18)
            # unrelated paths, including the rest of the real home, are untouched
            os.stat(str(ROOT))
            os.stat(REAL_HOME)
        finally:
            trust_tripwire.uninstall()

    def test_hook_fakes_the_passwd_home_and_logs_every_touch(self):
        base = Path(os.path.realpath(tempfile.mkdtemp(prefix="trust-hook-")))
        self.addCleanup(shutil.rmtree, base, True)
        log = base / "trip.log"
        fake = base / "fake-home"
        fake.mkdir()
        code = (
            "import os, pwd, sys\n"
            "print(pwd.getpwuid(os.getuid()).pw_dir)\n"
            "print(os.path.expanduser('~'))\n"
            "try:\n"
            "    os.lstat(sys.argv[1] + '/.local/bin/handoffkeep')\n"
            "except AssertionError as exc:\n"
            "    print('tripped')\n"
        )
        env = {"PATH": os.environ["PATH"], "HOME": str(fake), "PYTHONPATH": str(HOOK),
               "TRUST_FAKE_HOME": str(fake), "TRUST_TRIPWIRE_LOG": str(log)}
        out = subprocess.run([sys.executable, "-c", code, REAL_HOME], env=env, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.split("\n")[:3], [str(fake), str(fake), "tripped"])
        self.assertIn(".local/bin/handoffkeep", log.read_text())
        # without either variable the hook does nothing
        quiet = {"PATH": os.environ["PATH"], "PYTHONPATH": str(HOOK)}
        out = subprocess.run([sys.executable, "-c", "import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)"],
                             env=quiet, capture_output=True, text=True, check=True)
        self.assertEqual(out.stdout.strip(), REAL_HOME)


# ---------------------------------------------------------------------------
# 3. the real binaries, outside test mode, against a fake passwd home

HK_STUB = """#!@PYTHON@
import json, sys
with open(@LOG@, "a") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\\n")
DOCS = json.loads(@DOCS@)
if sys.argv[1:3] in (["doc", "get"], ["tasks", "comments"], ["tasks", "show"]) and len(sys.argv) > 3:
    doc = DOCS.get(sys.argv[3], DOCS.get("*"))
    if doc is not None:
        print(json.dumps(doc))
        raise SystemExit(0)
print("not_found")
raise SystemExit(1)
"""


def write_hk_stub(path, log, docs):
    body = (HK_STUB.replace("@PYTHON@", sys.executable).replace("@LOG@", json.dumps(str(log)))
            .replace("@DOCS@", json.dumps(json.dumps(docs))))
    write_exec(path, body)


def grant(job, extra=1, by="director-1"):
    return {"created_by": by, "body": "approved\nround-extension: job=%s extra=%d by=%s\n" % (job, extra, by)}


def tree(path):
    out = {}
    for item in sorted(Path(path).rglob("*")):
        if item.is_file():
            out[str(item.relative_to(path))] = hashlib.sha256(item.read_bytes()).hexdigest()
    return out


GIT_ENV = {"PATH": os.environ.get("PATH", ""), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
           "GIT_AUTHOR_NAME": "Trust Fixture", "GIT_AUTHOR_EMAIL": "trust@example.invalid",
           "GIT_COMMITTER_NAME": "Trust Fixture", "GIT_COMMITTER_EMAIL": "trust@example.invalid"}


class World:
    """A fake passwd home with a canonical inbox and handoffkeep, a builder-made
    directory, a temp root for test mode, and a git repo for round heads."""

    def __init__(self, case):
        self.case = case
        self.base = Path(os.path.realpath(tempfile.mkdtemp(prefix="trust-bin-")))
        case.addCleanup(shutil.rmtree, self.base, True)
        self.pw_home = self.base / "pw-home"
        self.jobs = self.pw_home / "work" / "herdr-inbox" / "jobs"
        self.jobs.mkdir(parents=True)
        (self.pw_home / ".local" / "share" / "arbiter").mkdir(parents=True)
        self.canon_hk = self.pw_home / ".local" / "bin" / "handoffkeep"
        self.canon_log = self.base / "canonical-hk.log"
        self.build = self.base / "builder"
        self.build.mkdir()
        self.tmp = self.base / "tmp"
        self.tmp.mkdir()
        self.trip = self.base / "tripwire.log"
        self.repo, self.heads = case.repo, case.heads
        self.docs = {}
        self.install_canonical_hk()
        case.addCleanup(self.assert_no_tripwire)

    def assert_no_tripwire(self):
        self.case.assertFalse(self.trip.exists(), self.trip.read_text() if self.trip.exists() else "")

    def install_canonical_hk(self, docs=None):
        write_hk_stub(self.canon_hk, self.canon_log, docs if docs is not None else self.docs)

    def stub(self, path, docs):
        path = Path(path)
        log = path.parent / (path.name + ".log")
        write_hk_stub(path, log, docs)
        return path, log

    def mkjob(self, root, job, parent="director-1", task=None):
        events = Path(root) / job / "events"
        events.mkdir(parents=True, exist_ok=True)
        payload = {"agent_label": job, "owner_lane": job + "-lane", "pane_id": "w:p1", "parent_lane": parent,
                   "repo": str(self.repo), "role": "builder", "t_level": "T2"}
        if task is not None:
            payload["task_id"] = task
        (events / "00001-job.claim.json").write_text(json.dumps({
            "created_at": "2026-10-01T00:00:00Z", "job_id": job, "kind": "job.claim", "payload": payload, "seq": 1}) + "\n")
        return events

    def env(self, test=False, **extra):
        env = {"PATH": safe_path(), "HOME": str(self.pw_home), "PYTHONPATH": str(HOOK),
               "TRUST_FAKE_HOME": str(self.pw_home), "TRUST_TRIPWIRE_LOG": str(self.trip),
               "TMPDIR": str(self.tmp), "WRK_NO_SLEEP": "1", "WRK_JOB_DELEGATE": "0",
               "PANEWIRE_BIN": str(self.base / "absent-panewire"), "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": os.devnull}
        if test:
            env["WRK_TEST_MODE"] = "1"
        for key, value in extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = str(value)
        return env

    def run(self, argv, env, cwd=None):
        return subprocess.run([str(a) for a in argv], env=env, capture_output=True, text=True, cwd=cwd or str(self.base))

    def wrk(self, wrk, *args, test=False, **extra):
        return self.run([wrk, *args], self.env(test=test, **extra))

    def open_rounds(self, wrk, root_env, job, count):
        for head in self.heads[:count]:
            out = self.run([wrk, "round", "open", job, "--head", head], root_env)
            self.case.assertEqual(out.returncode, 0, out.stderr)


class RealBinaryCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_dir = Path(os.path.realpath(tempfile.mkdtemp(prefix="trust-repo-")))
        cls.repo = cls.repo_dir / "repo"
        subprocess.run(["git", "init", "-q", str(cls.repo)], check=True, env=GIT_ENV)
        cls.heads = []
        for n in range(1, 5):
            (cls.repo / ("commit-%d" % n)).write_text("commit %d\n" % n)
            subprocess.run(["git", "-C", str(cls.repo), "add", "."], check=True, env=GIT_ENV)
            subprocess.run(["git", "-C", str(cls.repo), "commit", "-q", "-m", "fixture %d" % n], check=True, env=GIT_ENV)
            cls.heads.append(subprocess.run(["git", "-C", str(cls.repo), "rev-parse", "HEAD"], check=True,
                                            capture_output=True, text=True, env=GIT_ENV).stdout.strip())

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.repo_dir, ignore_errors=True)

    def setUp(self):
        self.w = World(self)
        self.wrk = str(WRK)

    def mutant(self, path, old, new, name):
        text = mutate(Path(path).read_text(encoding="utf-8"), old, new)
        target = self.w.tmp / ("mutant-" + name)
        target.write_text(text, encoding="utf-8")
        target.chmod(0o755)
        return str(target)

    def refusal_line(self, out, var, canonical):
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)
        lines = [line for line in out.stderr.splitlines() if line.strip()]
        self.assertEqual(len(lines), 1, out.stderr)
        self.assertIn(var, lines[0])
        self.assertIn(str(canonical), lines[0])

    def lib(self):
        path = self.w.base / "wrk-lib"
        path.write_text(WRK.read_text(encoding="utf-8").rsplit('case "${1:-}" in', 1)[0], encoding="utf-8")
        return path

    # -- repros: each is a function of the wrk (or arbiter) under test so the mutants can reuse it --

    def repro_inbox_redirect(self, wrk):
        w = self.w
        w.mkjob(w.jobs, "jobb")
        w.mkjob(w.build, "jobb")
        w.open_rounds(wrk, w.env(), "jobb", 3)
        verdict = w.base / "verdict.md"
        verdict.write_text("VERDICT: PASS @%s\n" % w.heads[0])
        before = (tree(w.jobs), tree(w.build))
        for args in (["round", "open", "jobb", "--head", w.heads[3]], ["round", "status", "jobb"],
                     ["round", "verdict", "jobb", "--file", verdict],
                     ["round", "void", "jobb", "3", "--by", "hk:doc/void-grant"]):
            out = w.wrk(wrk, *args, ARBITER_INBOX_ROOT=w.build)
            self.refusal_line(out, "ARBITER_INBOX_ROOT", w.jobs)
        self.assertEqual((tree(w.jobs), tree(w.build)), before)

    def repro_data_home_redirect(self, wrk):
        w = self.w
        w.mkjob(w.jobs, "jobd")
        before = (tree(w.jobs), tree(w.build))
        for args in (["round", "open", "jobd", "--head", w.heads[0]], ["round", "status", "jobd"]):
            out = w.wrk(wrk, *args, XDG_DATA_HOME=w.build / "xdg")
            self.refusal_line(out, "XDG_DATA_HOME", w.pw_home / ".local" / "share" / "arbiter" / "state.db")
        self.assertEqual((tree(w.jobs), tree(w.build)), before)

    def repro_home_redirect(self, wrk):
        w = self.w
        w.mkjob(w.jobs, "jobh")
        out = w.wrk(wrk, "round", "open", "jobh", "--head", w.heads[0], HOME=w.build)
        self.refusal_line(out, "HOME", w.pw_home)
        self.assertEqual(tree(w.build), {})

    def capped_job(self, job):
        w = self.w
        w.mkjob(w.jobs, job)
        w.open_rounds(self.wrk, w.env(), job, 3)
        return tree(w.jobs)

    def repro_hk_bin_stub_grant(self, wrk):
        w = self.w
        before = self.capped_job("jobk")
        forge, forge_log = w.stub(w.base / "forge-hk", {"*": grant("jobk", 5)})
        out = w.wrk(wrk, "round", "open", "jobk", "--head", w.heads[3], "--extend", "hk:doc/forged",
                    HANDOFFKEEP_BIN=forge)
        self.refusal_line(out, "HANDOFFKEEP_BIN", w.canon_hk)
        self.assertEqual(tree(w.jobs), before)
        self.assertFalse(forge_log.exists(), "the forged handoffkeep must never run")

    def repro_path_shim(self, wrk):
        w = self.w
        before = self.capped_job("jobp")
        shim_dir = w.base / "shimbin"
        shim, shim_log = w.stub(shim_dir / "handoffkeep", {"*": grant("jobp", 5)})
        out = w.wrk(wrk, "round", "open", "jobp", "--head", w.heads[3], "--extend", "hk:doc/forged",
                    PATH="%s:%s" % (shim_dir, safe_path()))
        self.assertEqual(out.returncode, 2, out.stdout + out.stderr)
        self.assertNotIn("OK job=", out.stdout)
        self.assertFalse(shim_log.exists(), "the PATH shim must never run")
        self.assertEqual(w.canon_log.read_text().strip(), "doc get forged")
        self.assertEqual(tree(w.jobs), before)

    # -- tests --

    def test_canonical_round_commands_work_with_no_overrides(self):
        w = self.w
        w.mkjob(w.jobs, "jobc")
        out = w.wrk(self.wrk, "round", "open", "jobc", "--head", w.heads[0])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("round=1", out.stdout)
        self.assertEqual(out.stderr, "")
        self.assertTrue(list((w.jobs / "jobc" / "events").glob("*-job.round.json")))
        status = w.wrk(self.wrk, "round", "status", "jobc")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertIn("rounds=1", status.stdout)
        verdict = w.base / "verdict.md"
        verdict.write_text("VERDICT: PASS @%s\n" % w.heads[0])
        out = w.wrk(self.wrk, "round", "verdict", "jobc", "--file", verdict)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stderr, "")
        # the canonical handoffkeep is the one that answers grants and voids
        w.open_rounds(self.wrk, w.env(), "jobc", 2)
        w.install_canonical_hk({"grant-jobc": grant("jobc"), "void-jobc": {
            "created_by": "director-1", "body": "round-void: job=jobc round=2 by=director-1\n"}})
        out = w.wrk(self.wrk, "round", "open", "jobc", "--head", w.heads[3], "--extend", "hk:doc/grant-jobc")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("round=4", out.stdout)
        self.assertEqual(out.stderr, "")
        out = w.wrk(self.wrk, "round", "void", "jobc", "2", "--by", "hk:doc/void-jobc")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("doc get grant-jobc", w.canon_log.read_text())

    def test_values_equal_to_the_canonical_path_are_accepted(self):
        w = self.w
        link = w.base / "pwlink"
        link.symlink_to(w.pw_home)
        cases = {
            "trailing slash": dict(ARBITER_INBOX_ROOT=str(w.jobs) + "/"),
            "symlinked parent": dict(ARBITER_INBOX_ROOT="%s/work/herdr-inbox/jobs" % link),
            "data home": dict(XDG_DATA_HOME=str(w.pw_home / ".local" / "share") + "/"),
            "symlinked HOME": dict(HOME=link),
        }
        for label, extra in cases.items():
            with self.subTest(case=label):
                job = "job-" + re.sub(r"\W", "", label)
                w.mkjob(w.jobs, job)
                out = w.wrk(self.wrk, "round", "open", job, "--head", w.heads[0], **extra)
                self.assertEqual(out.returncode, 0, out.stderr)
                self.assertEqual(out.stderr, "")
        w.mkjob(w.jobs, "job-hk")
        w.install_canonical_hk({"*": grant("job-hk")})
        w.open_rounds(self.wrk, w.env(), "job-hk", 3)
        out = w.wrk(self.wrk, "round", "open", "job-hk", "--head", w.heads[3], "--extend", "hk:doc/x",
                    HANDOFFKEEP_BIN=w.canon_hk)
        self.assertEqual(out.returncode, 0, out.stderr)

    def test_env_inbox_root_redirect_refused_then_honoured_in_test_mode(self):
        self.repro_inbox_redirect(self.wrk)
        w = self.w
        tbuild = w.tmp / "builder"
        tbuild.mkdir()
        w.mkjob(tbuild, "jobt")
        out = w.wrk(self.wrk, "round", "open", "jobt", "--head", w.heads[0], test=True,
                    ARBITER_INBOX_ROOT=tbuild, HOME=w.tmp / "home", XDG_DATA_HOME=w.tmp / "data")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(list((tbuild / "jobt" / "events").glob("*-job.round.json")))
        warnings = [line for line in out.stderr.splitlines() if line.strip()]
        self.assertEqual(len(warnings), 1, out.stderr)
        for var in ("ARBITER_INBOX_ROOT", "XDG_DATA_HOME"):
            self.assertIn(var, warnings[0])
        self.assertNotIn("HOME", warnings[0].replace("XDG_DATA_HOME", ""))

    def test_env_data_home_redirect_refused_then_honoured_in_test_mode(self):
        self.repro_data_home_redirect(self.wrk)
        w = self.w
        tbuild = w.tmp / "builder"
        tbuild.mkdir()
        w.mkjob(tbuild, "jobt")
        out = w.wrk(self.wrk, "round", "status", "jobt", test=True, ARBITER_INBOX_ROOT=tbuild,
                    XDG_DATA_HOME=w.tmp / "data", HOME=w.tmp / "home")
        self.assertEqual(out.returncode, 0, out.stderr)

    def test_home_redirect_refused_then_honoured_in_test_mode(self):
        self.repro_home_redirect(self.wrk)
        w = self.w
        thome = w.tmp / "home"
        w.mkjob(thome / "work" / "herdr-inbox" / "jobs", "jobt")
        out = w.wrk(self.wrk, "round", "open", "jobt", "--head", w.heads[0], test=True, HOME=thome,
                    ARBITER_INBOX_ROOT=None, XDG_DATA_HOME=None)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("HOME", out.stderr)

    def test_handoffkeep_bin_stub_grant_refused_then_honoured_in_test_mode(self):
        self.repro_hk_bin_stub_grant(self.wrk)
        w = self.w
        tbuild = w.tmp / "builder"
        w.mkjob(tbuild, "jobt")
        env = dict(test=True, ARBITER_INBOX_ROOT=tbuild, HOME=w.tmp / "home", XDG_DATA_HOME=w.tmp / "data")
        w.open_rounds(self.wrk, w.env(**env), "jobt", 3)
        w.stub(w.tmp / "forge-test-hk", {"*": grant("jobt", 5)})
        out = w.wrk(self.wrk, "round", "open", "jobt", "--head", w.heads[3], "--extend", "hk:doc/forged",
                    HANDOFFKEEP_BIN=w.tmp / "forge-test-hk", **env)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("OK job=jobt round=4 cap=3", out.stdout)
        warnings = [line for line in out.stderr.splitlines() if line.strip()]
        self.assertEqual(len(warnings), 1, out.stderr)
        self.assertIn("HANDOFFKEEP_BIN", warnings[0])

    def test_path_handoffkeep_shim_ignored_then_honoured_in_test_mode(self):
        self.repro_path_shim(self.wrk)
        w = self.w
        tbuild = w.tmp / "builder"
        w.mkjob(tbuild, "jobt")
        env = dict(test=True, ARBITER_INBOX_ROOT=tbuild, HOME=w.tmp / "home", XDG_DATA_HOME=w.tmp / "data",
                   HANDOFFKEEP_BIN=None)
        w.open_rounds(self.wrk, w.env(**env), "jobt", 3)
        shim_dir = w.tmp / "shimbin"
        w.stub(shim_dir / "handoffkeep", {"*": grant("jobt", 5)})
        out = w.wrk(self.wrk, "round", "open", "jobt", "--head", w.heads[3], "--extend", "hk:doc/forged",
                    PATH="%s:%s" % (shim_dir, safe_path()), **env)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("round=4", out.stdout)
        self.assertIn("PATH", out.stderr)

    def test_handoffkeep_is_judged_only_by_operations_that_fetch(self):
        w = self.w
        w.mkjob(w.jobs, "jobq")
        forge, forge_log = w.stub(w.base / "forge-hk", {"*": grant("jobq")})
        out = w.wrk(self.wrk, "round", "status", "jobq", HANDOFFKEEP_BIN=forge)
        self.assertEqual(out.returncode, 0, out.stderr)
        out = w.wrk(self.wrk, "round", "open", "jobq", "--head", w.heads[0], HANDOFFKEEP_BIN=forge)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertFalse(forge_log.exists())

    def test_insecure_canonical_handoffkeep_is_refused_where_it_is_used(self):
        w = self.w
        self.capped_job("jobi")
        before = tree(w.jobs)
        args = ["round", "open", "jobi", "--head", w.heads[3], "--extend", "hk:doc/grant-jobi"]
        w.install_canonical_hk({"grant-jobi": grant("jobi")})
        for label, mutate_hk in {
            "group-writable": lambda: w.canon_hk.chmod(0o775),
            "world-writable": lambda: w.canon_hk.chmod(0o757),
            "missing": lambda: w.canon_hk.unlink(),
        }.items():
            with self.subTest(case=label):
                w.install_canonical_hk({"grant-jobi": grant("jobi")})
                mutate_hk()
                out = w.wrk(self.wrk, *args)
                self.refusal_line(out, "canonical handoffkeep", w.canon_hk)
                self.assertEqual(tree(w.jobs), before)
        # the same binary is not needed by an open that is under the cap
        w.mkjob(w.jobs, "jobi2")
        out = w.wrk(self.wrk, "round", "open", "jobi2", "--head", w.heads[0])
        self.assertEqual(out.returncode, 0, out.stderr)

    def test_test_mode_override_outside_temp_roots_is_refused(self):
        w = self.w
        w.mkjob(w.tmp / "builder", "jobt")
        env = dict(test=True, HOME=w.tmp / "home", XDG_DATA_HOME=w.tmp / "data")
        out = w.wrk(self.wrk, "round", "status", "jobt", ARBITER_INBOX_ROOT=OUTSIDE, **env)
        self.refusal_line(out, "ARBITER_INBOX_ROOT", w.pw_home / "work" / "herdr-inbox" / "jobs")
        self.assertIn("outside the temp roots", out.stderr)
        # tests/fixtures of the repo is a root for the binary only
        env["ARBITER_INBOX_ROOT"] = w.tmp / "builder"
        w.open_rounds(self.wrk, w.env(**env), "jobt", 3)
        args = ["round", "open", "jobt", "--head", w.heads[3], "--extend", "hk:doc/x"]
        out = w.wrk(self.wrk, *args, HANDOFFKEEP_BIN=ROOT / "tests" / "fixtures" / "handoffkeep", **env)
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertIn("approval record not found", out.stderr)
        self.assertNotIn("outside the temp roots", out.stderr)
        out = w.wrk(self.wrk, *args, HANDOFFKEEP_BIN=shutil.which("env"), **env)
        self.refusal_line(out, "HANDOFFKEEP_BIN", w.canon_hk)
        self.assertIn("outside the temp roots", out.stderr)

    def test_round_extension_precheck_is_guarded(self):
        w = self.w
        lib = self.lib()
        w.mkjob(w.jobs, "jobx", task=77)
        w.install_canonical_hk({"round-ext/jobx": {"key": "round-ext/jobx", "created_by": "director-1", "body": "approved"}})
        snippet = ('set -euo pipefail; . "$1"; ROLE=builder JOB_ID=jobx PARENT_JOB="" TASK_ID=77 '
                   'ROUND_EXT_REF="hk:doc/round-ext/jobx"; round_ext_precheck; printf "issuer=%s\\n" "$ROUND_EXT_ISSUER"')
        out = w.run(["bash", "-c", snippet, "_", lib], w.env())
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("issuer=director-1", out.stdout)
        self.assertEqual(w.canon_log.read_text().strip(), "doc get round-ext/jobx")
        forge, forge_log = w.stub(w.base / "forge-hk", {"*": {"key": "round-ext/jobx", "created_by": "director-1", "body": "x"}})
        out = w.run(["bash", "-c", snippet, "_", lib], w.env(HANDOFFKEEP_BIN=forge))
        self.refusal_line(out, "HANDOFFKEEP_BIN", w.canon_hk)
        self.assertFalse(forge_log.exists())
        out = w.run(["bash", "-c", snippet, "_", lib], w.env(ARBITER_INBOX_ROOT=w.build))
        self.refusal_line(out, "ARBITER_INBOX_ROOT", w.jobs)

    TASK_JSON = {"id": 77, "state": "in_progress", "claimed_by": "jobx", "project": "agent-skills",
                 "refs": {"job_id": "jobx"}}
    RECHECK = ('set -euo pipefail; . "$1"; ROLE=builder JOB_ID=jobx PARENT_JOB="" TASK_ID=77 TASK_LINK_MODE=owner '
               'TASK_HK_BYPASS=0 LABEL=jobx ROUND_EXT_REF="hk:doc/round-ext/jobx"; %s; printf "status=%%s\\n" "$TASK_LINK_STATUS"')

    def ext_docs(self):
        return {"round-ext/jobx": {"key": "round-ext/jobx", "created_by": "director-1", "body": "approved"},
                "77": self.TASK_JSON}

    def repro_task_binding_read(self, lib):
        """hk_task_precheck, with a round-extension ref, reads the task binding as grant evidence."""
        w = self.w
        w.mkjob(w.jobs, "jobx", task=77)
        w.install_canonical_hk(self.ext_docs())
        snippet = self.RECHECK % "round_ext_precheck; hk_task_precheck"
        shim = w.base / "shimbin" / "handoffkeep"
        shim_log = w.stub(shim, {"*": self.TASK_JSON})[1]
        out = w.run(["bash", "-c", snippet, "_", lib], w.env(PATH="%s:%s" % (shim.parent, safe_path())))
        self.assertFalse(shim_log.exists(), "the PATH shim must never answer the task binding")
        self.assertEqual((out.returncode, out.stdout.strip()), (0, "status=already_linked"), out.stderr)
        self.assertEqual(w.canon_log.read_text().split("\n")[:2], ["doc get round-ext/jobx", "tasks show 77"])
        forge, forge_log = w.stub(w.base / "forge-hk", {"*": self.TASK_JSON})
        out = w.run(["bash", "-c", snippet, "_", lib], w.env(HANDOFFKEEP_BIN=forge))
        self.refusal_line(out, "HANDOFFKEEP_BIN", w.canon_hk)
        self.assertFalse(forge_log.exists())

    def test_round_extension_task_binding_read_is_guarded(self):
        self.repro_task_binding_read(self.lib())

    def test_round_extension_builder_recheck_is_guarded(self):
        w = self.w
        lib = self.lib()
        w.mkjob(w.jobs, "jobx", task=77)
        w.install_canonical_hk(self.ext_docs())
        snippet = self.RECHECK % "round_ext_builder_recheck"
        shim = w.base / "shimbin" / "handoffkeep"
        shim_log = w.stub(shim, {"*": self.TASK_JSON})[1]
        out = w.run(["bash", "-c", snippet, "_", lib], w.env(PATH="%s:%s" % (shim.parent, safe_path())))
        self.assertEqual((out.returncode, out.stdout.strip()), (0, "status=already_linked"), out.stderr)
        self.assertFalse(shim_log.exists())
        self.assertEqual(w.canon_log.read_text().split("\n")[:2], ["doc get round-ext/jobx", "tasks show 77"])
        tjobs = w.tmp / "jobs"
        w.mkjob(tjobs, "jobx", task=77)
        stub = w.stub(w.tmp / "hk", self.ext_docs())[0]
        out = w.run(["bash", "-c", snippet, "_", lib], w.env(test=True, ARBITER_INBOX_ROOT=tjobs, HOME=w.tmp / "home",
                                                              XDG_DATA_HOME=w.tmp / "data", HANDOFFKEEP_BIN=stub))
        self.assertEqual((out.returncode, out.stdout.strip()), (0, "status=already_linked"), out.stderr)

    def seed_old_job(self, root, job, rounds):
        events = Path(root) / job / "events"
        events.mkdir(parents=True, exist_ok=True)
        docs = [("00001-job.claim.json", {"kind": "job.claim", "at": "2026-10-18T00:00:00Z", "payload": {
                    "job_id": job, "owner_lane": "old-lane", "label": "old-label", "role": "builder", "task_id": 1}}),
                ("00002-job.spawned.json", {"kind": "job.spawned", "at": "2026-10-18T00:00:01Z", "payload": {
                    "job_id": job, "pane_id": "w1:p10", "tab_id": "w1:t10"}})]
        for n in range(1, rounds + 1):
            docs.append(("%05d-job.round.json" % (n + 2), {"kind": "job.round", "job_id": job, "round": n,
                                                            "at": "2026-10-18T00:00:%02dZ" % (n + 1)}))
        docs.append(("00020-job.revoked.json", {"kind": "job.revoked", "at": "2026-10-19T00:00:00Z",
                                                "payload": {"job_id": job, "owner_lane": "old-lane"}}))
        for name, doc in docs:
            (events / name).write_text(json.dumps(doc) + "\n")

    def repro_takeover_read(self, lib):
        w = self.w
        self.seed_old_job(w.jobs, "old-job", 2)
        self.seed_old_job(w.build, "old-job", 0)
        snippet = 'set -euo pipefail; . "$1"; takeover_old_job_check old-job; printf "rounds=%s\\n" "$TAKEOVER_ROUNDS_USED"'
        out = w.run(["bash", "-c", snippet, "_", lib], w.env())
        self.assertEqual((out.returncode, out.stdout.strip()), (0, "rounds=2"), out.stderr)
        out = w.run(["bash", "-c", snippet, "_", lib], w.env(ARBITER_INBOX_ROOT=w.build))
        self.refusal_line(out, "ARBITER_INBOX_ROOT", w.jobs)
        self.assertNotIn("rounds=", out.stdout)

    def test_takeover_inherited_round_read_is_guarded(self):
        self.repro_takeover_read(self.lib())
        w = self.w
        tmp_jobs = w.tmp / "jobs"
        self.seed_old_job(tmp_jobs, "old-job", 1)
        out = w.run(["bash", "-c", 'set -euo pipefail; . "$1"; takeover_old_job_check old-job; echo "rounds=$TAKEOVER_ROUNDS_USED"',
                     "_", self.lib()], w.env(test=True, ARBITER_INBOX_ROOT=tmp_jobs, HOME=w.tmp / "home",
                                             XDG_DATA_HOME=w.tmp / "data"))
        self.assertEqual((out.returncode, out.stdout.strip()), (0, "rounds=1"), out.stderr)

    def repro_arbiter_claim(self, arbiter):
        w = self.w
        db = w.pw_home / ".local" / "share" / "arbiter" / "state.db"
        before = tree(w.jobs)
        for var, value in (("ARBITER_INBOX_ROOT", w.build / "inbox"), ("XDG_DATA_HOME", w.build / "xdg"),
                           ("HOME", w.build / "home")):
            out = w.run([arbiter, "claim", "--job", "claimed-" + var.lower(), "--lane", "lane", "--t", "T1"],
                        w.env(**{var: value}))
            self.refusal_line(out, var, {"ARBITER_INBOX_ROOT": w.jobs, "XDG_DATA_HOME": db, "HOME": w.pw_home}[var])
            self.assertEqual(tree(w.build), {})
            self.assertFalse(db.exists())
        self.assertEqual(tree(w.jobs), before)

    def test_arbiter_claim_is_guarded(self):
        self.repro_arbiter_claim(str(ARBITER))
        w = self.w
        out = w.run([str(ARBITER), "claim", "--job", "claimed-ok", "--lane", "lane", "--t", "T1"], w.env())
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue((w.pw_home / ".local" / "share" / "arbiter" / "state.db").exists())
        self.assertTrue(list((w.jobs / "claimed-ok" / "events").glob("*-job.claim.json")))
        tbuild = w.tmp / "inbox"
        out = w.run([str(ARBITER), "claim", "--job", "claimed-test", "--lane", "lane", "--t", "T1"],
                    w.env(test=True, ARBITER_INBOX_ROOT=tbuild, XDG_DATA_HOME=w.tmp / "data", HOME=w.tmp / "home"))
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertTrue(list((tbuild / "claimed-test" / "events").glob("*-job.claim.json")))
        warnings = [line for line in out.stderr.splitlines() if "warning" in line]
        self.assertEqual(len(warnings), 1, out.stderr)
        out = w.run([str(ARBITER), "claim", "--job", "claimed-out", "--lane", "lane", "--t", "T1"],
                    w.env(test=True, ARBITER_INBOX_ROOT=OUTSIDE, XDG_DATA_HOME=w.tmp / "data", HOME=w.tmp / "home"))
        self.refusal_line(out, "ARBITER_INBOX_ROOT", w.jobs)

    def test_commands_outside_the_trust_path_keep_following_the_environment(self):
        w = self.w
        db = w.tmp / "xdg"
        inbox = w.tmp / "inbox"
        env = w.env(ARBITER_INBOX_ROOT=inbox, XDG_DATA_HOME=db, HOME=w.tmp / "home")
        out = w.run([str(ARBITER), "status", "--json"], env)
        self.assertNotEqual(out.returncode, 0)  # no DB there: it read the env path and did not refuse
        self.assertNotIn("canonical", out.stderr)
        self.assertIn(str(db / "arbiter" / "state.db"), out.stderr)
        self.assertEqual(w.wrk(self.wrk, "round", "--help").returncode, 0)

    # -- mutants at the real call sites --

    def red(self, repro, *args):
        with self.assertRaises(Exception):
            repro(*args)

    def test_mutant_round_open_skips_the_guard(self):
        mutant = self.mutant(WRK, '  if [[ -n "$extend" ]]; then wrk_trust_guard hk; else wrk_trust_guard; fi\n', ENV_FOLLOWING_HK, "open")
        self.red(self.repro_inbox_redirect, mutant)

    def test_mutant_round_verdict_skips_the_guard(self):
        mutant = self.mutant(WRK, '  [[ -n "$file" && -f "$file" ]] || die "round verdict requires an existing --file"\n  wrk_trust_guard\n',
                             '  [[ -n "$file" && -f "$file" ]] || die "round verdict requires an existing --file"\n' + ENV_FOLLOWING, "verdict")
        self.red(self.repro_inbox_redirect, mutant)

    def test_mutant_round_status_skips_the_guard(self):
        mutant = self.mutant(WRK, '  [[ $# -eq 1 ]] || die "round status accepts only a job id"\n  wrk_trust_guard\n',
                             '  [[ $# -eq 1 ]] || die "round status accepts only a job id"\n' + ENV_FOLLOWING, "status")
        self.red(self.repro_data_home_redirect, mutant)

    def test_mutant_round_void_skips_the_guard(self):
        mutant = self.mutant(WRK, '  [[ -n "$ref" ]] || die "round void requires --by REF"\n  wrk_trust_guard hk\n',
                             '  [[ -n "$ref" ]] || die "round void requires --by REF"\n' + ENV_FOLLOWING_HK, "void")
        self.red(self.repro_inbox_redirect, mutant)

    def test_mutant_round_extension_precheck_skips_the_guard(self):
        mutant = self.mutant(WRK, '  wrk_trust_guard hk\n  handoffkeep="$WRK_TRUST_HK"\n',
                             ENV_FOLLOWING_HK + '  handoffkeep="$WRK_TRUST_HK"\n', "ext")
        lib = self.w.base / "mutant-lib"
        lib.write_text(Path(mutant).read_text().rsplit('case "${1:-}" in', 1)[0])
        w = self.w
        w.mkjob(w.jobs, "jobx", task=77)
        forge, forge_log = w.stub(w.base / "forge-hk", {"*": {"key": "round-ext/jobx", "created_by": "director-1", "body": "x"}})
        snippet = ('set -euo pipefail; . "$1"; ROLE=builder JOB_ID=jobx PARENT_JOB="" TASK_ID=77 '
                   'ROUND_EXT_REF="hk:doc/round-ext/jobx"; round_ext_precheck; printf "issuer=%s\\n" "$ROUND_EXT_ISSUER"')
        with self.assertRaises(AssertionError):
            out = w.run(["bash", "-c", snippet, "_", lib], w.env(HANDOFFKEEP_BIN=forge))
            self.refusal_line(out, "HANDOFFKEEP_BIN", w.canon_hk)

    def test_mutant_task_binding_read_follows_hk_bin(self):
        mutant = self.mutant(WRK, '    wrk_trust_guard hk\n    handoffkeep=""\n    [[ ! -x "$WRK_TRUST_HK" ]] || handoffkeep="$WRK_TRUST_HK"\n',
                             '    handoffkeep="$(hk_bin)"\n', "taskbind")
        lib = self.w.base / "mutant-lib"
        lib.write_text(Path(mutant).read_text().rsplit('case "${1:-}" in', 1)[0])
        self.red(self.repro_task_binding_read, lib)

    def test_mutant_takeover_read_skips_the_guard(self):
        mutant = self.mutant(WRK, '  wrk_trust_guard\n  events="${WRK_TRUST_JOBS_ROOT:?trust guard did not run}/$old/events"\n',
                             ENV_FOLLOWING + '  events="${WRK_TRUST_JOBS_ROOT:?trust guard did not run}/$old/events"\n', "takeover")
        lib = self.w.base / "mutant-lib"
        lib.write_text(Path(mutant).read_text().rsplit('case "${1:-}" in', 1)[0])
        self.red(self.repro_takeover_read, lib)

    def test_mutant_arbiter_claim_skips_the_guard(self):
        mutant = self.mutant(ARBITER, "        if args.command in TRUST_COMMANDS:\n            enforce_trust()\n", "", "arbiter")
        self.red(self.repro_arbiter_claim, mutant)

    def test_mutant_handoffkeep_bin_honoured_outside_test_mode(self):
        mutant = self.mutant(WRK, '            if hk_env:\n                found = hk_env if "/" in hk_env else (shutil.which(hk_env, path=search) or hk_env)\n'
                             '                judge("HANDOFFKEEP_BIN", found, canon["hk"], "handoffkeep", ())\n'
                             '            hk = trust_secure_binary(canon["hk"], uid)',
                             '            hk = hk_env or trust_secure_binary(canon["hk"], uid)', "hkenv")
        self.red(self.repro_hk_bin_stub_grant, mutant)

    def test_mutant_path_handoffkeep_used_outside_test_mode(self):
        mutant = self.mutant(WRK, '            hk = trust_secure_binary(canon["hk"], uid)',
                             '            hk = shutil.which("handoffkeep", path=search) or trust_secure_binary(canon["hk"], uid)', "hkpath")
        self.red(self.repro_path_shim, mutant)

    def test_mutant_test_mode_accepts_a_path_outside_the_temp_roots(self):
        mutant = self.mutant(WRK, "        if not any(trust_under(resolved, root) for root in allowed):", "        if False:", "outside")
        w = self.w
        w.mkjob(w.tmp / "builder", "jobt")

        def repro(wrk):
            out = w.wrk(wrk, "round", "status", "jobt", test=True, HOME=w.tmp / "home",
                        XDG_DATA_HOME=w.tmp / "data", ARBITER_INBOX_ROOT=OUTSIDE)
            self.refusal_line(out, "ARBITER_INBOX_ROOT", w.pw_home / "work" / "herdr-inbox" / "jobs")

        repro(self.wrk)
        self.red(repro, mutant)

    def test_wrk_help_names_the_rule(self):
        out = subprocess.run([self.wrk, "round", "--help"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0)
        for word in ("WRK_TEST_MODE", "canonical", "HANDOFFKEEP_BIN", "narrows"):
            self.assertIn(word, out.stdout)


if __name__ == "__main__":
    unittest.main()
