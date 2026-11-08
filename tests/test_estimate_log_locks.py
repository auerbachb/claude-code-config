"""Actual estimate-log CLI writers against private ledgers and synthetic GitHub."""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('ESTIMATE_LOCK_TEST_SOURCE', ROOT / '.claude/scripts/estimate-log.sh'))
SHELL = os.environ.get('ESTIMATE_LOCK_TEST_SHELL', 'bash')


class EstimateLockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='estimate-lock-test-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        scripts = self.home / '.claude/scripts'
        scripts.mkdir(parents=True)
        self.script = self.root / 'estimate-log.sh'
        shutil.copy2(SOURCE, self.script)
        ref = scripts / 'pr-issue-ref.sh'
        ref.write_text('#!/bin/sh\necho 77\n')
        ref.chmod(0o700)
        self.log = self.root / 'ledger.jsonl'
        self.lock = Path(str(self.log) + '.lock')
        self.env = dict(os.environ, HOME=str(self.home), ESTIMATE_LOG_FILE=str(self.log),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        LOCK_FIXTURE=str(self.root), REAL_CAT=shutil.which('cat'),
                        REAL_DATE=shutil.which('date'))
        for name in ('GH_REPO', 'CLAUDE_SESSION_REPO'):
            self.env.pop(name, None)
        self.tool('gh', '''import json,sys
p=sys.argv[2] if len(sys.argv)>2 else ''
if sys.argv[1:3]==['pr','list']:
 print('[{"number":101},{"number":102}]')
elif '/pulls/' in p and '--jq' in sys.argv:
 print('2')
elif '/pulls/' in p:
 print(json.dumps({'merged_at':'2026-09-01T14:00:00Z','state':'closed','created_at':'2026-09-01T11:00:00Z','commits':2}))
elif p.endswith('/comments'): print('[]')
elif p.endswith('/issues/77'): print('{"body":""}')
else: sys.exit(99)
''')
        self.tool('cat', '''import os,sys,time
from pathlib import Path
r=Path(os.environ['LOCK_FIXTURE'])
if os.environ.get('LOCK_TEST_HOLD')=='1' and any('.estimate-log-tmp-' in a for a in sys.argv[1:]):
 (r/'held').write_text('ready')
 deadline=time.monotonic()+20
 while not (r/'go').exists():
  if time.monotonic()>deadline: sys.exit(98)
  time.sleep(.02)
os.execv(os.environ['REAL_CAT'], [os.environ['REAL_CAT']]+sys.argv[1:])
''')
        self.tool('date', '''import os,sys
from pathlib import Path
if sys.argv[1:]==['+%s'] and os.environ.get('LOCK_TEST_FAST_TIMEOUT')=='1':
 p=Path(os.environ['LOCK_TEST_CLOCK']); n=int(p.read_text()) if p.exists() else 0
 p.write_text(str(n+1)); print(1000000 if n==0 else 1001000)
else: os.execv(os.environ['REAL_DATE'],[os.environ['REAL_DATE']]+sys.argv[1:])
''')

    def tool(self, name, body):
        p = self.bin / name
        p.write_text('#!' + sys.executable + '\n' + body)
        p.chmod(0o700)

    def start(self, number, hold=False, fast=False, arguments=None):
        env = dict(self.env, LOCK_TEST_HOLD='1' if hold else '0',
                   LOCK_TEST_FAST_TIMEOUT='1' if fast else '0',
                   LOCK_TEST_CLOCK=str(self.root / ('clock-' + str(number))))
        p = subprocess.Popen([SHELL, str(self.script)] + (arguments or ['--append', str(number), '--repo', 'acme/widgets']),
                             env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.addCleanup(self.stop, p)
        return p

    def stop(self, p):
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGKILL)
        p.communicate(timeout=5)

    def finish(self, p):
        out, err = p.communicate(timeout=12)
        self.assertEqual(p.returncode, 0, err.decode())  # append remains best-effort
        return err.decode()

    def wait_held(self, p, name='held'):
        end = time.monotonic() + 10
        while not (self.root / name).exists():
            self.assertIsNone(p.poll(), 'holder exited before append boundary')
            self.assertLess(time.monotonic(), end, 'holder did not reach append boundary')
            time.sleep(.02)

    def rows(self):
        return [json.loads(s)['pr'] for s in self.log.read_text().splitlines()] if self.log.exists() else []

    def dead_holder(self):
        p = self.start(101, hold=True)
        self.wait_held(p)
        self.stop(p)
        self.assertTrue(self.lock.exists())
        return p

    def test_old_live_cli_holder_is_never_reaped(self):
        p = self.start(101, hold=True)
        self.wait_held(p)
        os.utime(self.lock, (1, 1))  # older than the former 120s stale threshold
        before = (self.lock / 'token').read_bytes()
        self.assertIn('could not acquire', self.finish(self.start(102, fast=True)))
        self.assertEqual((self.lock / 'token').read_bytes(), before)
        self.assertEqual(self.rows(), [])
        (self.root / 'go').touch()
        self.finish(p)
        self.assertEqual(self.rows(), [101])

    def test_killed_cli_holder_is_recovered(self):
        self.dead_holder()
        self.finish(self.start(102))
        self.assertEqual(self.rows(), [102])
        self.assertFalse(self.lock.exists())

    def test_two_recovery_contenders_preserve_both_writes(self):
        self.dead_holder()
        a, b = self.start(102), self.start(103)
        self.finish(a)
        self.finish(b)
        self.assertEqual(sorted(self.rows()), [102, 103])
        self.assertFalse(self.lock.exists())

    def test_unknown_foreign_and_unpublished_owners_are_retained(self):
        for index, owner in enumerate((None, 'bad metadata', '99999999 foreign.invalid old', '0 '+socket.gethostname()+' old')):
            with self.subTest(owner=owner):
                self.lock.mkdir()
                (self.lock / 'token').write_text('old\n')
                if owner is not None:
                    (self.lock / 'owner').write_text(owner+'\n')
                os.utime(self.lock, (1, 1))
                self.assertIn('could not acquire', self.finish(self.start(110+index, fast=True)))
                self.assertEqual((self.lock / 'token').read_text(), 'old\n')
                self.assertEqual(self.rows(), [])
                shutil.rmtree(self.lock)

    def test_abandoned_recovery_guard_is_retained(self):
        self.dead_holder()
        guard = self.lock / ('reaper-' + (self.lock / 'token').read_text().strip())
        guard.mkdir()
        self.assertIn('could not acquire', self.finish(self.start(102, fast=True)))
        self.assertTrue(guard.is_dir())
        self.assertEqual(self.rows(), [])

    def test_generation_replaced_before_recovery_guard_is_not_wedged(self):
        dead = self.dead_holder()
        real_mkdir = shutil.which('mkdir')
        self.env['REAL_MKDIR'] = real_mkdir
        self.env['LOCK_TEST_SUCCESSOR_PID'] = str(os.getpid())
        self.env['LOCK_TEST_SUCCESSOR_HOST'] = socket.gethostname()
        self.tool('mkdir', '''import os,shutil,sys
from pathlib import Path
if len(sys.argv)==2 and Path(sys.argv[1]).name.startswith('reaper'):
 lock=Path(sys.argv[1]).parent
 marker=Path(os.environ['LOCK_FIXTURE'])/'generation-replaced'
 if not marker.exists():
  shutil.rmtree(lock);lock.mkdir()
  (lock/'token').write_text('999-123456789-3\\n')
  (lock/'owner').write_text(os.environ['LOCK_TEST_SUCCESSOR_PID']+' '+os.environ['LOCK_TEST_SUCCESSOR_HOST']+' 999-123456789-3\\n')
  marker.touch()
os.execv(os.environ['REAL_MKDIR'],[os.environ['REAL_MKDIR']]+sys.argv[1:])
''')
        self.assertIn('could not acquire', self.finish(self.start(102, fast=True)))
        self.assertTrue((self.root / 'generation-replaced').exists())
        self.assertEqual((self.lock / 'token').read_text(), '999-123456789-3\n')
        self.assertEqual(list(self.lock.glob('reaper*')), [])
        self.assertEqual(self.rows(), [])
        # The replacement later dies: its own acquisition can still recover.
        (self.lock / 'owner').write_text(str(dead.pid)+' '+socket.gethostname()+' 999-123456789-3\n')
        self.finish(self.start(103))
        self.assertEqual(self.rows(), [103])
        self.assertFalse(self.lock.exists())

    def test_failed_recovery_allocation_does_not_strand_guard(self):
        self.dead_holder()
        real_mktemp = shutil.which('mktemp')
        self.tool('mktemp', 'import os,sys\nif any(".reaped." in a for a in sys.argv[1:]): sys.exit(88)\nos.execv('+repr(real_mktemp)+',['+repr(real_mktemp)+']+sys.argv[1:])\n')
        self.assertIn('could not acquire', self.finish(self.start(102)))
        self.assertEqual(list(self.lock.glob('reaper*')), [])
        self.assertEqual(self.rows(), [])
        (self.bin / 'mktemp').unlink()
        self.finish(self.start(103))
        self.assertEqual(self.rows(), [103])

    def test_orphaned_append_child_keeps_generation_locked(self):
        p = self.start(101, hold=True)
        self.addCleanup((self.root / 'go').touch)
        self.wait_held(p)
        os.kill(p.pid, signal.SIGKILL)  # deliberately leave its cat child alive
        p.wait(timeout=5)
        before = (self.lock / 'token').read_bytes()
        self.assertIn('could not acquire', self.finish(self.start(102, fast=True)))
        self.assertEqual((self.lock / 'token').read_bytes(), before)
        self.assertEqual(self.rows(), [])
        (self.root / 'go').touch()
        p.communicate(timeout=8)
        self.assertEqual(self.rows(), [101])
        self.finish(self.start(103))
        self.assertEqual(self.rows(), [101, 103])

    def test_orphaned_rewrite_child_cannot_overwrite_new_append(self):
        self.finish(self.start(101))
        row = json.loads(self.log.read_text()); row['rounds'] = None
        self.log.write_text(json.dumps(row, separators=(',', ':'))+'\n')
        self.env['REAL_MV'] = shutil.which('mv')
        self.tool('mv', '''import os,sys,time
from pathlib import Path
r=Path(os.environ['LOCK_FIXTURE'])
if sys.argv[-1]==os.environ['ESTIMATE_LOG_FILE']:
 (r/'held-mv').touch()
 deadline=time.monotonic()+20
 while not (r/'go-mv').exists():
  if time.monotonic()>deadline: sys.exit(98)
  time.sleep(.02)
os.execv(os.environ['REAL_MV'],[os.environ['REAL_MV']]+sys.argv[1:])
''')
        p = self.start(102, arguments=['--backfill', '--repo', 'acme/widgets', '--limit', '2'])
        self.addCleanup((self.root / 'go-mv').touch)
        self.wait_held(p, 'held-mv')
        os.kill(p.pid, signal.SIGKILL)
        p.wait(timeout=5)
        before = self.log.read_bytes()
        self.assertIn('could not acquire', self.finish(self.start(103, fast=True)))
        self.assertEqual(self.log.read_bytes(), before)
        (self.root / 'go-mv').touch()
        p.communicate(timeout=8)
        self.finish(self.start(104))
        self.assertEqual(self.rows(), [101, 102, 104])
        self.assertTrue(all(row['rounds']==2 for row in map(json.loads,self.log.read_text().splitlines())))

    def test_unpublished_writer_pid_remains_unknown(self):
        self.dead_holder()
        token = (self.lock / 'token').read_text().strip()
        (self.lock / 'writer').write_text('pending '+token+'\n')
        self.assertIn('could not acquire', self.finish(self.start(102, fast=True)))
        self.assertTrue(self.lock.exists())
        self.assertEqual(self.rows(), [])

    def test_release_does_not_remove_successor_token(self):
        p = self.start(101, hold=True)
        self.wait_held(p)
        (self.lock / 'token').write_text('successor\n')
        (self.root / 'go').touch()
        self.finish(p)
        self.assertEqual((self.lock / 'token').read_text(), 'successor\n')

    def test_release_does_not_remove_an_empty_successor_token(self):
        p = self.start(101, hold=True)
        self.wait_held(p)
        (self.lock / 'token').write_text('')
        (self.root / 'go').touch()
        self.finish(p)
        self.assertTrue(self.lock.is_dir())

    def test_append_backfill_rounds_patch_and_rollup(self):
        self.finish(self.start(101))
        self.finish(self.start(101))
        self.assertEqual(self.rows(), [101])
        row = json.loads(self.log.read_text())
        row['rounds'] = None
        foreign = dict(row, repo='other/repository')
        self.log.write_text(json.dumps(foreign,separators=(',',':'))+'\n'+json.dumps(row,separators=(',',':'))+'\n')
        r = subprocess.run([SHELL, str(self.script), '--backfill', '--repo', 'acme/widgets', '--limit', '2'],
                           env=self.env, capture_output=True, text=True, timeout=12)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = [json.loads(line) for line in self.log.read_text().splitlines()]
        target = [v for v in rows if v['repo']=='acme/widgets']
        self.assertEqual(sorted(v['pr'] for v in target), [101, 102])
        self.assertTrue(all(v['rounds']==2 for v in target))
        self.assertIn(foreign, rows)
        before = self.log.read_bytes()
        report = self.root / 'rollup.md'
        r = subprocess.run([SHELL, str(self.script), '--rollup', '--repo', 'acme/widgets', '--output', str(report)],
                           env=self.env, capture_output=True, text=True, timeout=12)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertGreater(report.stat().st_size, 200)
        self.assertEqual(self.log.read_bytes(), before)
        self.assertFalse(self.lock.exists())

    def test_pid_inspection_error_is_not_dead_holder_evidence(self):
        self.dead_holder()
        self.tool('ps', 'import sys\nsys.exit(2)\n')
        self.assertIn('could not acquire', self.finish(self.start(102, fast=True)))
        self.assertTrue(self.lock.exists())
        self.assertEqual(self.rows(), [])

    def test_failed_owner_publication_refuses_write(self):
        real_mv = shutil.which('mv')
        self.tool('mv', 'import os,sys\nif any(a.endswith("/owner.tmp") for a in sys.argv[1:]): sys.exit(97)\nos.execv('+repr(real_mv)+',['+repr(real_mv)+']+sys.argv[1:])\n')
        self.assertIn('could not acquire', self.finish(self.start(101)))
        self.assertEqual(self.rows(), [])
        self.assertFalse(self.lock.exists())


if __name__ == '__main__':
    unittest.main()
