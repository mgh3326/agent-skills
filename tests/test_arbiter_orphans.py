"""hk 1991: orphan reconciliation through real CLI, temp sqlite and agent fixtures."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARBITER = Path(os.environ.get('ARBITER_ORPHAN_TEST_BIN', ROOT / 'bin/arbiter'))


class Orphans(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ao-', dir='/tmp')
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ, WRK_TEST_MODE='1',
                        SCOPEFUEL_BIN=str(ROOT / 'tests/fixtures/scopefuel'))
        for name in ('HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME',
                     'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR', 'CODEX_HOME', 'ARBITER_INBOX_ROOT', 'TMPDIR'):
            path = self.base / name.lower(); path.mkdir(); self.env[name] = str(path)
        self.db = self.base / 'xdg_data_home/arbiter/state.db'
        self.agents = self.base / 'agents.json'
        self.agent_list([])
        self.gate = self.base / 'gate.out'
        result = subprocess.run([str(ROOT / 'tests/fixtures/scopefuel'), 'gate', '-m', 'codex-max'],
                                env=self.env, capture_output=True, text=True, check=True)
        self.gate.write_text(result.stdout)

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, *args, want=0):
        result = subprocess.run([sys.executable, str(ARBITER), *args, '--json'], env=self.env,
                                capture_output=True, text=True, timeout=15, check=False)
        self.assertEqual(result.returncode, want, result.stdout + result.stderr)
        return json.loads(result.stdout) if want == 0 else result.stderr

    def agent_list(self, statuses):
        self.agents.write_text(json.dumps({'result': {'agents': [
            {'name': 'agent-J', 'agent_status': s} for s in statuses]}}))

    def claim(self, quota=True, lease=False):
        self.call('claim', '--job', 'J', '--agent-label', 'agent-J', '--lane', 'fixture', '--t', 'T2')
        if quota:
            self.call('lease', '--job', 'J', '--kind', 'quota_pool', '--profile', 'codex-max',
                      '--gate-output', str(self.gate))
        if lease:
            self.call('lease', '--job', 'J', '--kind', 'path', '--resource', 'remaining-path')

    def rows(self, sql):
        with sqlite3.connect(self.db) as con:
            return con.execute(sql).fetchall()

    def state(self):
        return self.rows("SELECT state FROM jobs WHERE job_id='J'")[0][0]

    def events(self):
        return [json.loads(r[0])['payload'] for r in self.rows(
            "SELECT payload FROM events WHERE job_id='J' AND kind='job.orphan_release'")]

    def gc(self, want=0):
        return self.call('gc', '--herdr-agent-list', str(self.agents), want=want)

    def manual(self, want=0):
        return self.call('release', '--force', '--job', 'J', '--herdr-agent-list', str(self.agents), want=want)

    def assert_released(self, forced=False):
        self.assertEqual(self.state(), 'released', 'orphan job stayed leased')
        events = self.events()
        self.assertEqual(len(events), 1, 'orphan release must emit exactly once')
        event = events[0]
        self.assertEqual(event['job_id'], 'J')
        self.assertEqual(event['prior_state'], 'leased')
        self.assertEqual(event['agent_label'], 'agent-J')
        self.assertEqual(event['herdr_status'], [])
        self.assertIn('absent', event['reason'])
        self.assertEqual(event.get('forced', False), forced)

    def test_gc_10_12_releases_once_and_reclaim_succeeds(self):
        self.claim()
        self.gc()
        self.assertEqual(self.rows('SELECT * FROM quota_pool_records'), [])
        self.assert_released()
        self.gc()
        self.assertEqual(len(self.events()), 1)
        self.call('claim', '--job', 'J', '--lane', 'fixture', '--t', 'T2', '--reclaim-released')
        self.assertEqual(self.state(), 'claimed', 'reclaim still needs job-dup-ok')

    def test_live_agent_unchanged(self):
        self.claim()
        self.agent_list(['working'])
        self.gc()
        self.assertEqual(self.state(), 'leased')
        self.assertEqual(len(self.rows('SELECT * FROM quota_pool_records')), 1)
        self.assertEqual(self.events(), [])
        self.assertIn('live', self.manual(want=6))

    def test_unknown_agent_refuses_and_rolls_back(self):
        self.claim()
        self.agent_list(['unknown'])
        self.assertIn('unknown', self.gc(want=6))
        self.assertEqual(self.state(), 'leased')
        self.assertEqual(len(self.rows('SELECT * FROM quota_pool_records')), 1)
        self.assertEqual(self.events(), [])
        self.assertIn('unknown', self.manual(want=6))

    def test_remaining_path_lease_blocks_transition(self):
        self.claim(lease=True)
        self.gc()
        self.assertEqual(self.state(), 'leased', 'remaining lease was ignored')
        self.assertEqual(len(self.rows('SELECT * FROM leases')), 1)
        self.assertEqual(self.events(), [])
        self.assertIn('remaining-path', self.manual(want=6))

    def test_manual_orphan_releases_once(self):
        self.claim()
        # Reproduce a pre-fix gc deletion, leaving the leased job behind.
        with sqlite3.connect(self.db) as con:
            con.execute('DELETE FROM quota_pool_records')
        self.manual()
        self.assert_released(forced=True)
        self.manual(want=4)
        self.assertEqual(len(self.events()), 1)

    def test_manual_refuses_quota_row_left(self):
        self.claim()
        self.assertIn('codex', self.manual(want=6))
        self.assertEqual(self.state(), 'leased')
        self.assertEqual(len(self.rows('SELECT * FROM quota_pool_records')), 1)

    def test_rowless_unknown_live_and_unmapped_refuse(self):
        self.claim()
        with sqlite3.connect(self.db) as con:
            con.execute('DELETE FROM quota_pool_records')
        for status in ('unknown', 'working'):
            self.agent_list([status])
            self.gc(want=6 if status == 'unknown' else 0)
            self.assertEqual(self.state(), 'leased')
            self.manual(want=6)
        self.agent_list([])
        with sqlite3.connect(self.db) as con:
            con.execute("UPDATE events SET payload=json_remove(payload, '$.payload.agent_label') WHERE kind='job.claim'")
        self.gc(want=6)
        self.assertIn('mapping', self.manual(want=6))
        self.assertEqual(self.state(), 'leased')

    def test_concurrent_gc_manual_and_reclaim(self):
        self.claim()
        with sqlite3.connect(self.db) as con:
            con.execute('DELETE FROM quota_pool_records')
        commands = [
            ['gc', '--herdr-agent-list', str(self.agents)],
            ['release', '--force', '--job', 'J', '--herdr-agent-list', str(self.agents)],
            ['claim', '--job', 'J', '--lane', 'fixture', '--t', 'T2', '--reclaim-released'],
        ]
        procs = [subprocess.Popen([sys.executable, str(ARBITER), *args, '--json'],
                                 env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 text=True) for args in commands]
        for proc in procs:
            out, err = proc.communicate(timeout=15)
            self.assertIn(proc.returncode, (0, 4), out + err)
        self.assertEqual(len(self.events()), 1, 'concurrent release emitted twice')
        self.assertIn(self.state(), ('released', 'claimed'))
        if self.state() == 'released':
            self.call('claim', '--job', 'J', '--lane', 'fixture', '--t', 'T2', '--reclaim-released')
        self.assertEqual(self.state(), 'claimed')

    def test_mutants_break_orphan_invariants(self):
        mutations = [
            ('gc-transition', '            result = _orphan_release(con, job_id, herdr_agents, moment)',
             '            result = None', 'test_gc_10_12_releases_once_and_reclaim_succeeds',
             'orphan job stayed leased'),
            # Bypass both unknown checks at the real reconciliation call sites.
            ('unknown', 'if "unknown" in statuses:', 'if False:',
             'test_unknown_agent_refuses_and_rolls_back', '0 != 6'),
            ('lease-left', '            if con.execute("SELECT 1 FROM leases WHERE job_id = ?", (job_id,)).fetchone():',
             '            if False:', 'test_remaining_path_lease_blocks_transition',
             'remaining lease was ignored'),
        ]
        for name, old, new, case, invariant in mutations:
            with self.subTest(mutant=name):
                source = ARBITER.read_text()
                self.assertEqual(source.count(old), 1)
                source = source.replace(old, new, 1)
                if name == 'unknown':
                    source = source.replace('if HERDR_LIVE_STATUS in statuses or "unknown" in statuses:',
                                            'if HERDR_LIVE_STATUS in statuses:')
                if name == 'lease-left':
                    source = source.replace('    if leases or quota:', '    if quota:')
                binary = self.base / ('mutant-' + name)
                binary.write_text(source)
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()), 'Orphans.' + case],
                                        env=dict(self.env, ARBITER_ORPHAN_TEST_BIN=str(binary)),
                                        capture_output=True, text=True, timeout=30, check=False)
                self.assertNotEqual(result.returncode, 0, 'mutant survived: ' + name)
                self.assertIn('AssertionError:', result.stderr)
                self.assertIn(invariant, result.stderr)
                self.assertNotIn('ERROR:', result.stderr, 'a crash is not assertion RED')


if __name__ == '__main__':
    unittest.main(verbosity=2)
