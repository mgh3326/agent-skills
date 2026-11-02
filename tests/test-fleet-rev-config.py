#!/usr/bin/env python3
"""Configuration selection must preserve the intended fleet during cutover."""
import argparse
import contextlib
import io
import os
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

MODULE = runpy.run_path(os.environ.get('FLEET_REV_BIN') or str(Path(__file__).resolve().parents[1] / 'bin/fleet-rev'))

class FleetConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = patch.dict(os.environ, {'HOME': str(self.home)}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.args = argparse.Namespace(extra=None, skip=None, only=None)
        self.stderr = io.StringIO()
        self.redirect = contextlib.redirect_stderr(self.stderr)
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)

    def hosts(self):
        return MODULE['build_hosts'](self.args, argparse.ArgumentParser())

    def config(self, relative):
        path = self.home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('[hosts.remote]\nssh = "remote-alias"\n')
        return path

    def assert_refusal(self):
        with self.assertRaises(SystemExit) as raised:
            self.hosts()
        self.assertEqual(raised.exception.code, 2)
        self.assertIn('FLEET_HOSTS_CONFIG', self.stderr.getvalue())

    def test_legacy_variable_missing_file_refuses(self):
        os.environ['WRK_HOSTS_CONFIG'] = str(self.home / 'missing.toml')
        self.assert_refusal()

    def test_legacy_default_file_refuses(self):
        self.config('.config/wrk/hosts.toml')
        self.assert_refusal()

    def test_legacy_xdg_file_refuses(self):
        os.environ['XDG_CONFIG_HOME'] = str(self.home / 'xdg')
        self.config('xdg/wrk/hosts.toml')
        self.assert_refusal()

    def test_canonical_default_keeps_remote_despite_obsolete_variable(self):
        os.environ['WRK_HOSTS_CONFIG'] = str(self.home / 'missing.toml')
        self.config('.config/fleet/hosts.toml')
        self.assertEqual([(h.name, h.alias) for h in self.hosts()], [('local', 'local'), ('remote', 'remote-alias')])

    def test_explicit_canonical_wins(self):
        os.environ['WRK_HOSTS_CONFIG'] = str(self.home / 'missing.toml')
        os.environ['FLEET_HOSTS_CONFIG'] = str(self.config('current.toml'))
        self.assertEqual([h.name for h in self.hosts()], ['local', 'remote'])

    def test_missing_without_legacy_still_warns(self):
        self.assertEqual([h.name for h in self.hosts()], ['local'])
        self.assertIn('warning', self.stderr.getvalue())

if __name__ == '__main__':
    unittest.main()
