"""hk1991: orphan reconciliation uses temp sqlite and authoritative list fixtures."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARBITER = Path(os.environ.get('ARBITER_OWNER_TEST_BIN', ROOT / 'bin/arbiter'))


class OrphanOwner(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='arb-owner-', dir='/tmp')
        self.base = Path(self.tmp.name)
        self.env = dict(os.environ)
        for key in ('HOME','XDG_CONFIG_HOME','XDG_DATA_HOME','XDG_STATE_HOME','XDG_CACHE_HOME',
                    'XDG_RUNTIME_DIR','CODEX_HOME','ARBITER_INBOX_ROOT','TMPDIR'):
            path = self.base / key.lower(); path.mkdir(); self.env[key] = str(path)
        self.env.update(WRK_TEST_MODE='1', SCOPEFUEL_BIN=str(ROOT / 'tests/fixtures/scopefuel'),
                        HERDR_BIN=str(ROOT / 'tests/fixtures/herdr'))
        self.db = Path(self.env['XDG_DATA_HOME']) / 'arbiter/state.db'
        self.gate = self.base / 'gate.out'
        result = subprocess.run([self.env['SCOPEFUEL_BIN'], 'gate', '-m', 'codex-max'],
                                env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.gate.write_text(result.stdout)
        self.agents = self.base / 'agents.json'
        self.fixture([])

    def tearDown(self):
        self.tmp.cleanup()

    def fixture(self, statuses):
        self.agents.write_text(json.dumps({'result': {'agents': [
            {'name': name, 'agent_status': status} for name, status in statuses]}}))

    def run_cli(self, *args, rc=0):
        result = subprocess.run([str(ARBITER), *args, '--json'], env=self.env,
                                capture_output=True, text=True, timeout=15, check=False)
        self.assertEqual(result.returncode, rc, f'{args}: {result.stdout} {result.stderr}')
        return json.loads(result.stdout) if rc == 0 else result.stderr

    def claim(self, name='job', quota=True):
        self.run_cli('claim', '--job', name, '--lane', 'test', '--t', 'T2')
        if quota:
            self.run_cli('lease', '--job', name, '--kind', 'quota_pool', '--profile',
                         'codex-max', '--gate-output', str(self.gate))

    def gc(self, **kwargs):
        return self.run_cli('gc', '--herdr-agent-list', str(self.agents), **kwargs)

    def release(self, name='job', **kwargs):
        return self.run_cli('release', '--force', '--job', name,
                            '--herdr-agent-list', str(self.agents), **kwargs)

    def sql(self, query, params=()):
        with sqlite3.connect(self.db) as con:
            return con.execute(query, params).fetchall()

    def state(self, name='job'):
        return self.sql('SELECT state FROM jobs WHERE job_id=?', (name,))[0][0]

    def events(self):
        return [json.loads(row[0])['payload'] for row in self.sql(
            "SELECT payload FROM events WHERE kind='job.orphan_release'")]

    def no_rows(self):
        self.sql('DELETE FROM quota_pool_records')

    def test_gc_1012_shape_and_reclaim(self):
        self.claim()
        self.gc()
        self.assertEqual(self.state(), 'released', 'gc left an orphan leased')
        self.assertEqual(self.sql('SELECT * FROM quota_pool_records'), [])
        events = self.events()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]['job_id'], 'job')
        self.assertEqual(events[0]['prior_state'], 'leased')
        self.assertEqual(events[0]['agent_label'], 'job')
        self.assertEqual(events[0]['herdr_status'], [])
        self.assertIn('absent', events[0]['reason'])
        self.gc()
        self.assertEqual(len(self.events()), 1, 'repeat gc duplicated orphan event')
        self.run_cli('claim', '--reclaim-released', '--job', 'job', '--lane', 'test', '--t', 'T2')
        self.assertEqual(self.state(), 'claimed')

    def test_gc_present_idle_done_blocked_working_keep_job(self):
        for status in ('idle', 'done', 'blocked', 'working'):
            self.claim(status)
        self.fixture([(s, s) for s in ('idle', 'done', 'blocked', 'working')])
        self.gc()
        for status in ('idle', 'done', 'blocked', 'working'):
            self.assertEqual(self.state(status), 'leased', 'present agent was released: ' + status)
            if status == 'working': self.no_rows()
            error = self.release(status, rc=3)
            self.assertIn('live', error)
        self.assertEqual(self.events(), [])
        self.gc()
        self.assertTrue(all(self.state(s) == 'leased' for s in ('idle','done','blocked','working')))

    def test_unknown_is_atomic_refusal_with_and_without_quota(self):
        self.claim('gone')
        self.claim('unknown')
        self.fixture([('unknown', 'unknown')])
        self.gc(rc=6)
        self.assertEqual(len(self.sql('SELECT * FROM quota_pool_records')), 2,
                         'unknown allowed partial quota cleanup')
        self.assertEqual(self.state('gone'), 'leased')
        self.sql("DELETE FROM quota_pool_records WHERE job_id='unknown'")
        self.gc(rc=6)
        self.assertEqual(len(self.sql('SELECT * FROM quota_pool_records')), 1)
        artifacts = Path(self.env['ARBITER_INBOX_ROOT']) / 'gone/events'
        self.assertFalse(list(artifacts.glob('*stale_cleanup*')), 'refused gc published cleanup evidence')
        self.no_rows()
        self.gc(rc=6)
        self.release('unknown', rc=6)
        self.assertEqual(self.state('unknown'), 'leased', 'unknown agent was released')
        self.assertEqual(self.events(), [])

    def test_remaining_lease_blocks_gc_and_manual(self):
        self.claim()
        self.run_cli('lease', '--job', 'job', '--resource', 'path-left', '--kind', 'path')
        self.gc()
        self.assertEqual(self.state(), 'leased', 'gc released with a remaining lease')
        error = self.release(rc=3)
        self.assertIn('lease', error)
        self.assertIn('path-left', error)
        self.assertEqual(self.events(), [])

    def test_force_orphan_and_quota_left(self):
        self.claim()
        error = self.release(rc=3)
        self.assertIn('quota', error)
        self.no_rows()
        self.release()
        self.assertEqual(self.state(), 'released', 'force did not release rowless orphan')
        self.assertEqual(len(self.events()), 1)
        self.assertIs(self.events()[0]['forced'], True)
        self.release(rc=3)
        self.assertEqual(len(self.events()), 1)

    def test_unmapped_refuses_gc_and_manual(self):
        self.claim()
        # This is the old v2 claim format, without exact identity evidence.
        rows = self.sql("SELECT seq,payload FROM events WHERE kind='job.claim'")
        event = json.loads(rows[0][1]); event['payload'].pop('agent_label')
        self.sql('UPDATE events SET payload=? WHERE seq=?', (json.dumps(event), rows[0][0]))
        self.gc(rc=6)
        self.no_rows()
        self.gc(rc=6)
        self.release(rc=6)
        self.assertEqual(self.state(), 'leased')
        self.assertEqual(self.events(), [])

    def test_gc_manual_race_emits_once(self):
        self.claim(); self.no_rows()
        args = [[str(ARBITER), 'gc', '--herdr-agent-list', str(self.agents), '--json'],
                [str(ARBITER), 'release', '--force', '--job', 'job',
                 '--herdr-agent-list', str(self.agents), '--json']]
        procs = [subprocess.Popen(a, env=self.env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True) for a in args]
        results = [p.communicate(timeout=15) for p in procs]
        self.assertEqual(procs[0].returncode, 0, results)
        self.assertIn(procs[1].returncode, (0, 3), results)
        self.assertEqual(self.state(), 'released')
        self.assertEqual(len(self.events()), 1, 'concurrent gc/manual emitted duplicate release')

    def test_orphan_mutants_are_assertion_red(self):
        source = ARBITER.read_text()
        cases = [
            ('transition', '            _release_orphan(con, evidence, moment)\n', '            pass\n',
             'test_gc_1012_shape_and_reclaim', 'gc left an orphan leased'),
            ('lease', '            " AND NOT EXISTS (SELECT 1 FROM leases WHERE leases.job_id = jobs.job_id)"\n',
             '            " AND 1 = 1"\n', 'test_remaining_lease_blocks_gc_and_manual',
             'gc released with a remaining lease'),
            ('unknown', '\n    if "unknown" in statuses:\n', '\n    statuses.discard("unknown")\n    if False:\n',
             'test_unknown_is_atomic_refusal_with_and_without_quota', '0 != 6'),
            ('idle-done', '    return {"job_id": job_id, "prior_state": "leased", "agent_label": label,\n            "herdr_status": sorted(statuses),\n',
             '    return {"job_id": job_id, "prior_state": "leased", "agent_label": label,\n            "herdr_status": sorted(statuses & {"working"}),\n',
             'test_gc_present_idle_done_blocked_working_keep_job', 'present agent was released'),
        ]
        for name, old, new, case, invariant in cases:
            with self.subTest(mutant=name):
                self.assertEqual(source.count(old), 1, 'mutant anchor must be unique: ' + old)
                binary = self.base / ('mutant-' + name)
                binary.write_text(source.replace(old, new, 1)); binary.chmod(0o755)
                result = subprocess.run([sys.executable, str(Path(__file__).resolve()), 'OrphanOwner.' + case],
                    env=dict(self.env, ARBITER_OWNER_TEST_BIN=str(binary)), capture_output=True,
                    text=True, timeout=40, check=False)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('AssertionError:', result.stderr)
                self.assertIn(invariant, result.stderr)
                self.assertNotIn('ERROR:', result.stderr, 'a crash is not assertion RED')


if __name__ == '__main__':
    unittest.main(verbosity=2)
