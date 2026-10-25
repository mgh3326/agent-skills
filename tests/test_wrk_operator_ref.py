"""hk 1990: real wrk call sites with argv-recording launch/gate stubs only."""
import argparse
import json
import subprocess
import unittest

import test_wrk_round_extension as fixtures


class OperatorRefTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.RoundExtensionSpawn()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def request_ref(self, args):
        self.assertIn("--operator-request", args)
        index = args.index("--operator-request") + 1
        self.assertLess(index, len(args), "operator-request must have a REF value")
        return args[index]

    def paths(self, **kwargs):
        process, calls = self.fixture.run_spawn(**kwargs)
        # Exit 91 is the fixture admission stop, before any real agent or sentinel.
        self.assertEqual(process.returncode, 91, process.stderr)
        paths = [args for args in calls if args[:2] in (["policy", "launch"], ["gate", "-m"])]
        self.assertEqual(len(paths), 2, calls)
        return paths

    def test_operator_request_value_reaches_launch_and_gate(self):
        for ref in ("hk:task/1786", "hk:doc/a ref;$(touch not-executed)&*x"):
            with self.subTest(ref=ref):
                paths = self.paths(model="haiku", role="tester", ref=None, purpose=None,
                                   extra=("--operator-request", ref))
                for args in paths:
                    self.assertEqual(self.request_ref(args), ref)
                self.assertFalse((self.fixture.base / "not-executed").exists())

    def test_astra_fable_implicit_counsel_preserve_ref_role_and_exit(self):
        for model in ("codex-astra", "fable"):
            paths = self.paths(model=model, role=None, ref=None, purpose="operator-request",
                               extra=("--operator-request", "hk:task/1786"))
            for args in paths:
                self.assertEqual(self.request_ref(args), "hk:task/1786")
                self.assertEqual(args[args.index("--role") + 1], "counsel")
                self.assertEqual(args[args.index("--purpose") + 1], "operator-request")

    def test_round_extension_builder_ref_argv_and_exit(self):
        for model in ("codex-astra", "fable"):
            paths = self.paths(model=model, role="builder", ref=fixtures.REF)
            for args in paths:
                self.assertEqual(self.request_ref(args), fixtures.REF)
                self.assertEqual(args[args.index("--role") + 1], "builder")
                self.assertEqual(args[args.index("--purpose") + 1], "round-extension")

    def test_shared_launch_fixture_accepts_bare_and_valued_ref(self):
        for ref in ((), ("hk:task/1786",)):
            process = subprocess.run([
                str(fixtures.ROOT / "tests/fixtures/scopefuel"), "policy", "launch", "fable",
                "--operator-request", *ref, "--purpose", "operator-request", "--role", "counsel",
                "--effort", "xhigh", "--json",
            ], env=self.fixture.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            payload = json.loads(process.stdout)
            self.assertEqual(payload["model_id"], "claude-fable-5-1")
            self.assertEqual(payload["effort"], "xhigh")

    def test_bare_optional_ref_does_not_consume_following_options(self):
        # Pin the existing scopefuel argparse contract (nargs='?', const=True).
        # A bare flag loses the REF but does not misparse these subsequent options.
        parser = argparse.ArgumentParser()
        parser.add_argument("--operator-request", nargs="?", const=True, default=False)
        for option in ("purpose", "role", "effort"):
            parser.add_argument("--" + option)
        args = parser.parse_args(["--operator-request", "--purpose", "architect",
                                  "--role", "counsel", "--effort", "xhigh"])
        self.assertIs(args.operator_request, True)
        self.assertEqual((args.purpose, args.role, args.effort), ("architect", "counsel", "xhigh"))


if __name__ == "__main__":
    unittest.main()
