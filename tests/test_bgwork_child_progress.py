"""Real ceiling ticks with isolated registry, heartbeat and child artifacts."""
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
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
        self.private = self.root/('claude-bgprogress-'+self.session+'.d')
        self.cache = self.private/'cache.json'

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
        for status in ('done', 'failed', 'stopped', 'rearming', 'rearmed', 'abandoned'):
            self.row['status'] = status
            self.publish()
            self.assertEqual(self.command('--tick'), '')
        self.row['status'] = 'stop_failed'
        self.publish()
        self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))

    def test_scope_and_malformed_inventory_remain_unknown(self):
        self.row['session_id'] = 'foreign-session'
        self.inventory['repos'][''] = {'legacy_field': 'unrelated to this session'}
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
        diagnostic = self.private/'diagnostic'
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

    def test_shared_marker_symlinks_never_truncate_or_follow_victim(self):
        victim = self.root/'owner-file'
        victim.write_text('preserve this owner data')
        # The former predictable shared-directory failure path is untouched.
        legacy = self.root/('claude-bgprogress-'+self.session+'.unknown')
        legacy.symlink_to(victim)
        Path(self.env['CLAUDE_SESSION_STATE_FILE']).write_text('bad JSON')
        self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))
        self.assertEqual(victim.read_text(), 'preserve this owner data')
        # Even injected entries inside an owned fixture directory cannot
        # redirect private writes or the lock to another file.
        for name in ('unknown', 'diagnostic', 'lock'):
            target = self.private/name
            target.unlink(missing_ok=True)
            target.symlink_to(victim)
            self.command('--tick')
            self.assertEqual(victim.read_text(), 'preserve this owner data')
            target.unlink(missing_ok=True)
        self.assertEqual(self.private.stat().st_mode & 0o777, 0o700)

    def test_precreated_private_directory_symlink_fails_closed(self):
        victim = self.root/'other-directory'
        victim.mkdir()
        (victim/'keep').write_text('owner file')
        self.private.symlink_to(victim, target_is_directory=True)
        self.assertIn('CHILD PROGRESS UNKNOWN', self.command('--tick'))
        self.command('--clear')
        self.assertEqual([p.name for p in victim.iterdir()], ['keep'])
        self.assertEqual((victim/'keep').read_text(), 'owner file')

    def test_wide_readable_inventory_never_publishes_an_unreadable_cache(self):
        # Unicode escapes make the old repeated-path cache exceed1MiB even
        # under macOS's shorter physical path limit. All artifacts are real.
        directory = self.root
        for _ in range(3):
            directory = directory/('界'*75)
            directory.mkdir()
        output, checkpoint = directory/'output', directory/'checkpoint'
        output.write_text('running')
        checkpoint.write_text('checkpoint')
        rows = [dict(self.row, task_id=('runtime-'+str(n)+'-'+'x'*100),
                     output_file=str(output), checkpoint_path=str(checkpoint)) for n in range(200)]
        self.inventory['repos']['fixture/repo']['background_tasks'] = rows
        self.publish()
        self.assertEqual(self.command('--tick'), '')
        self.age_observation()
        notice = self.command('--tick')
        self.assertEqual(notice.count('CHILD STALL SUSPECT'), 200)
        self.assertLess(self.cache.stat().st_size, 1024*1024)
        self.assertEqual(self.command('--tick'), '')
        self.command('--clear')
        self.assertFalse(self.cache.exists())


    def test_unicode_runtime_notices_fit_without_losing_dedup(self):
        rows = [dict(self.row, task_id='界'*250+('%06d'%n)) for n in range(200)]
        self.inventory['repos']['fixture/repo']['background_tasks'] = rows
        self.publish()
        self.assertEqual(self.command('--tick'), '')
        self.age_observation()
        notice = self.command('--tick')
        self.assertEqual(notice.count('CHILD STALL SUSPECT'), 200)
        self.assertLessEqual(len(notice.encode()), 256*1024)
        self.assertEqual(self.command('--tick'), '')
        self.assertFalse((self.private/'pending-cache.json').exists())

    def observer_process(self, code):
        helper = self.script.parent/'lib/bgwork-child-progress.py'
        setup = "import importlib.util,os,signal,sys\nfrom pathlib import Path\nspec=importlib.util.spec_from_file_location('observer_fixture',sys.argv[1]);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\n"
        return subprocess.run([sys.executable,'-c',setup+code,str(helper),self.session,
                               str(self.root/('claude-bgprogress-'+self.session)),str(self.cache)],
                              env=self.env,capture_output=True,timeout=8,start_new_session=True)

    def test_failed_caller_delivery_does_not_commit_notice_dedup(self):
        self.command('--tick')
        self.age_observation()
        before = self.cache.read_bytes()
        result = self.observer_process("""
class BrokenBuffer:
 def write(self,value): raise OSError('fixture delivery failed')
 def flush(self): pass
class Sink:
 buffer=BrokenBuffer()
 def write(self,value): return len(value)
 def flush(self): pass
m.sys.stdout=Sink()
m.main(sys.argv[2],sys.argv[3])
""")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.cache.read_bytes(),before)
        self.assertTrue((self.private/'pending-cache.json').exists())
        self.assertIn('CHILD STALL SUSPECT',self.command('--tick'))
        self.assertEqual(self.command('--tick'),'')

    def test_observer_killed_after_pending_write_retries_notice(self):
        self.command('--tick')
        self.age_observation()
        before = self.cache.read_bytes()
        result = self.observer_process("""
original=m.private_write
def interrupted_write(path,body):
 original(path,body)
 if path.name=='pending-cache.json':os.kill(os.getpid(),signal.SIGKILL)
m.private_write=interrupted_write
m.observe(sys.argv[2],Path(sys.argv[4]))
""")
        self.assertEqual(result.returncode,-signal.SIGKILL,result.stderr)
        self.assertEqual(self.cache.read_bytes(),before)
        self.assertTrue((self.private/'pending-cache.json').exists())
        self.assertIn('CHILD STALL SUSPECT',self.command('--tick'))
        self.assertEqual(self.command('--tick'),'')
        self.command('--clear')
        self.assertFalse((self.private/'pending-cache.json').exists())

    def test_output_overflow_leaves_prior_dedup_until_recoverable(self):
        repo='o'*100+'/'+('r'*100)
        rows=[dict(self.row,repo_key=repo,task_id='😀'*250+('%06d'%n)) for n in range(200)]
        self.inventory={'repos':{repo:{'background_tasks':rows}}}
        self.publish()
        self.assertEqual(self.command('--tick'),'')
        self.age_observation()
        before=self.cache.read_bytes()
        self.assertIn('CHILD PROGRESS UNKNOWN',self.command('--tick'))
        self.assertEqual(self.cache.read_bytes(),before)
        self.inventory['repos'][repo]['background_tasks']=rows[:1]
        self.publish()
        self.assertIn('CHILD STALL SUSPECT',self.command('--tick'))
        self.assertEqual(self.command('--tick'),'')


if __name__ == '__main__':
    unittest.main()
