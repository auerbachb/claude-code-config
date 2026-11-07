"""Real ceiling ticks with isolated registry, heartbeat and child artifacts."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


class ChildProgressTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='child-progress-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.script = Path(__file__).resolve().parents[1]/'.claude/scripts/bgwork-ceiling.sh'
        self.session = 'fixture-session'
        self.env = dict(os.environ, HOME=str(self.root), CLAUDE_BGWORK_MARKER_DIR=str(self.root),
                        CLAUDE_BGWORK_LOG_DIR=str(self.root), CLAUDE_SESSION_STATE_FILE=str(self.root/'state.json'))
        self.env.pop('BGWORK_CHILD_STALL_S', None)
        self.env.pop('CLAUDE_BGWORK_CEILING_S', None)
        self.output = self.root/'child-output'
        self.output.write_text('started\n')
        self.row = dict(task_id='exact-runtime', type='agent', status='running', session_id=self.session,
                        repo_key='fixture/repo', started_at='2026-01-01T00:00:00Z', output_file=str(self.output))
        self.inventory = {'repos': {'fixture/repo': {'background_tasks': [self.row]}}}
        self.publish()
        self.command('--note-started', 'Agent')
        self.heartbeat = self.root/('claude-heartbeat-'+self.session)
        self.heartbeat.touch()
        self.cache = self.root/('claude-bgprogress-'+self.session+'.json')

    def publish(self):
        Path(self.env['CLAUDE_SESSION_STATE_FILE']).write_text(json.dumps(self.inventory))

    def command(self, *args):
        result = subprocess.run(['bash', str(self.script), *args, '--session', self.session],
                                env=self.env, text=True, capture_output=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def age_observation(self):
        cache = json.loads(self.cache.read_text())
        for row in cache['tasks'].values():
            row['last_activity_at'] = time.time()-1000
        self.cache.write_text(json.dumps(cache))

    def test_stall_while_parent_keeps_polling_and_independent_dedup(self):
        self.assertEqual(self.command('--tick'), '')
        self.age_observation()
        self.heartbeat.touch()
        notice = self.command('--tick')
        self.assertIn('CHILD STALL SUSPECT', notice)
        self.assertIn('exact-runtime', notice)
        self.assertIn('Do not stop or respawn', notice)
        self.assertEqual(self.command('--tick'), '')
        self.heartbeat.touch()
        self.assertEqual(self.command('--tick'), '')
        self.output.write_text('new child activity\n')
        self.assertEqual(self.command('--tick'), '')
        self.age_observation()
        self.heartbeat.unlink()
        self.assertIn('CHILD STALL SUSPECT', self.command('--tick'))

    def test_healthy_long_running_child_and_new_generation(self):
        old = time.time()-86400
        os.utime(self.output, (old, old))
        self.assertEqual(self.command('--tick'), '')  # no invented pre-observation history
        self.age_observation()
        self.output.write_text('child continues\n')
        self.assertEqual(self.command('--tick'), '')
        self.age_observation()
        self.row['started_at'] = '2026-02-01T00:00:00Z'
        self.publish()
        self.assertEqual(self.command('--tick'), '')

    def test_unknown_recovery_and_terminal_identity(self):
        self.output.unlink()
        self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))
        self.assertEqual(self.command('--tick'), '')
        self.output.write_text('recovered')
        self.assertEqual(self.command('--tick'), '')
        self.output.unlink()
        self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))
        for status in ('done', 'failed', 'stopped', 'rearmed', 'abandoned'):
            self.row['status'] = status
            self.publish()
            self.assertEqual(self.command('--tick'), '')
        self.row['status'] = 'stop_failed'
        self.publish()
        self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))

    def test_scope_and_malformed_inventory_remain_unknown(self):
        self.row['session_id'] = 'foreign-session'
        self.publish()
        self.assertEqual(self.command('--tick'), '')
        self.row['session_id'] = self.session
        for field, value in [('started_at', None), ('repo_key', 'wrong/repo'), ('status', 'mystery')]:
            original = self.row[field]
            self.row[field] = value
            self.publish()
            self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))
            self.row[field] = original
        Path(self.env['CLAUDE_SESSION_STATE_FILE']).write_text('not JSON')
        self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))
        self.assertEqual(self.command('--tick'), '')
        diagnostic = self.root/('claude-bgprogress-'+self.session+'.diagnostic')
        self.assertTrue(diagnostic.is_file())
        self.assertEqual(diagnostic.stat().st_mode & 0o777, 0o600)
        self.publish()
        self.assertEqual(self.command('--tick'), '')

    def test_parent_and_child_notices_do_not_suppress_each_other(self):
        self.command('--tick')
        self.age_observation()
        old = time.time()-1800
        os.utime(self.heartbeat, (old, old))
        notice = self.command('--tick')
        self.assertIn('CEILING BREACH', notice)
        self.assertIn('CHILD STALL SUSPECT', notice)
        self.assertEqual(self.command('--tick'), '')
        self.assertEqual(json.loads(Path(self.env['CLAUDE_SESSION_STATE_FILE']).read_text()), self.inventory)

    def test_hanging_registry_read_is_bounded_and_never_clean(self):
        source = Path(self.env['CLAUDE_SESSION_STATE_FILE'])
        source.unlink()
        os.mkfifo(source)
        start = time.monotonic()
        self.assertIn('CHILD PROGRESS UNKNOWN: progress_probe_timeout', self.command('--tick'))
        self.assertLess(time.monotonic()-start, 6)
        source.unlink()
        self.publish()
        self.assertEqual(self.command('--tick'), '')


if __name__ == '__main__':
    unittest.main()
