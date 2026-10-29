"""arbiter finds the quota CLI: SCOPEFUEL_BIN, then pacelever, then scopefuel."""
import importlib.machinery
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load_arbiter():
    loader = importlib.machinery.SourceFileLoader("arbiter_mod", str(ROOT / "bin" / "arbiter"))
    spec = importlib.util.spec_from_loader("arbiter_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def fake(dirpath, name):
    p = Path(dirpath) / name
    p.write_text("#!/bin/sh\nexit 0\n")
    p.chmod(p.stat().st_mode | stat.S_IXUSR)
    return str(p)


class QuotaBinTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_arbiter()
        self.env = dict(os.environ)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.env)

    def test_prefers_pacelever_over_scopefuel(self):
        with tempfile.TemporaryDirectory() as d:
            pl = fake(d, "pacelever")
            fake(d, "scopefuel")
            os.environ.pop("SCOPEFUEL_BIN", None)
            os.environ["PATH"] = d
            self.assertEqual(self.mod.scopefuel_bin(), pl)

    def test_falls_back_to_scopefuel(self):
        with tempfile.TemporaryDirectory() as d:
            sf = fake(d, "scopefuel")
            os.environ.pop("SCOPEFUEL_BIN", None)
            os.environ["PATH"] = d
            self.assertEqual(self.mod.scopefuel_bin(), sf)

    def test_explicit_env_wins(self):
        with tempfile.TemporaryDirectory() as d:
            fake(d, "pacelever")
            os.environ["SCOPEFUEL_BIN"] = "/opt/quota"
            os.environ["PATH"] = d
            self.assertEqual(self.mod.scopefuel_bin(), "/opt/quota")

    def test_missing_is_refused(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ.pop("SCOPEFUEL_BIN", None)
            os.environ["PATH"] = d
            with self.assertRaises(self.mod.ArbiterError):
                self.mod.scopefuel_bin()


if __name__ == "__main__":
    unittest.main()
