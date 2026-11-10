"""Prove real invitation CLI cleanup, with surviving-descendant controls."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


HELPER = Path(__file__).resolve().parents[1] / '.claude/scripts/lib/bugbot_invitation.py'


def process_state(pid):
    """Inspect only a recorded PID; zombies have terminated but await reaping."""
    result = subprocess.run(['ps', '-o', 'pgid=,stat=', '-p', str(pid)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, timeout=2)
    row = result.stdout.strip()
    if not row:
        if result.returncode not in (0, 1):
            raise AssertionError('ps failed: ' + result.stderr)
        return None
    if result.returncode != 0:
        raise AssertionError('ps failed with a process row: ' + result.stderr)
    pgid, state = row.split()
    return int(pgid), state


def terminated(pid, group, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        state = process_state(pid)
        if state is None:
            return True
        if state[0] != group:
            raise AssertionError('recorded PID no longer belongs to the fixture')
        if state[1].startswith('Z'):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.02)


class InvitationInterruptionTest(unittest.TestCase):
    def exercise(self, mode, mutant=False):
        with tempfile.TemporaryDirectory(prefix='invitation-process-fixture-') as directory:
            root = Path(directory)
            binary, pid_file = root / 'gh', root / 'api.json'
            # Both processes inherit the reader-created API process group. Publish
            # one atomic record only after the real descendant has been spawned.
            binary.write_text('#!' + sys.executable + '\n' + '''import json,os,subprocess
from pathlib import Path
child = subprocess.Popen(['sleep', '30'])
target = Path(os.environ['GH_FIXTURE_PID'])
staging = target.with_suffix('.tmp')
staging.write_text(json.dumps({'api': os.getpid(), 'descendant': child.pid}))
staging.replace(target)
child.wait()
''')
            binary.chmod(0o755)
            helper = HELPER
            if mutant:
                original = HELPER.read_text()
                needle = 'os.killpg(proc.pid, signal.SIGKILL)'
                self.assertEqual(original.count(needle), 2, 'verify both mutation sites')
                changed = original.replace(needle, 'os.kill(proc.pid, signal.SIGKILL)')
                self.assertNotIn(needle, changed)
                compile(changed, 'direct-child-only.py', 'exec')
                helper = root / 'direct-child-only.py'
                helper.write_text(changed)
            env = dict(os.environ, HOME=str(root), TMPDIR=str(root),
                       PATH=str(root) + os.pathsep + os.environ['PATH'],
                       GH_FIXTURE_PID=str(pid_file))
            proc = subprocess.Popen([sys.executable, str(helper), '--repo', 'fixture/repo',
                                     '--pr', '7', '--head', 'a' * 40],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
            pids = None
            started = time.monotonic()
            try:
                deadline = started + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists(), 'both real fixture processes must start')
                pids = json.loads(pid_file.read_text())
                api, descendant = pids['api'], pids['descendant']
                self.assertEqual(process_state(api)[0], api)
                state = process_state(descendant)
                self.assertEqual(state[0], api, 'descendant belongs to the fixture API group')
                self.assertFalse(state[1].startswith('Z'), 'descendant must be live before trigger')
                if mode == 'interrupt':
                    proc.send_signal(signal.SIGTERM)
                stdout, stderr = proc.communicate(timeout=18 if mode == 'timeout' else 5)
                self.assertLess(time.monotonic() - started, 20)
                if mode == 'interrupt':
                    self.assertEqual(proc.returncode, 130, stderr.decode())
                    self.assertEqual(stdout, b'', 'interruption cannot emit a clean decision')
                else:
                    self.assertEqual(proc.returncode, 0, stderr.decode())
                    decision = json.loads(stdout)
                    self.assertEqual((decision['awaited'], decision['certainty'], decision['reason']),
                                     (True, 'unknown', 'read_timeout'))
                self.assertIsNone(process_state(api), 'reader must reap its direct API child')
                if mutant:
                    state = process_state(descendant)
                    self.assertIsNotNone(state, 'mutation must leave a real survivor')
                    self.assertEqual(state[0], api)
                    self.assertFalse(state[1].startswith('Z'))
                    with self.assertRaisesRegex(AssertionError, 'descendant survived'):
                        self.assertTrue(terminated(descendant, api, timeout=0.1),
                                        'descendant survived')
                else:
                    self.assertTrue(terminated(descendant, api), 'descendant survived')
            finally:
                # These handles/PIDs came only from this fixture. Recheck group
                # ownership before signaling recorded descendants, never scan or
                # match host processes by name. Retain the record on early failure.
                if proc.poll() is None:
                    proc.kill()
                proc.communicate(timeout=5)
                if pids is None and pid_file.exists():
                    pids = json.loads(pid_file.read_text())
                if pids is not None:
                    for pid in (pids['descendant'], pids['api']):
                        state = process_state(pid)
                        if state is not None and not state[1].startswith('Z'):
                            self.assertEqual(state[0], pids['api'], 'cleanup ownership mismatch')
                            try:
                                os.kill(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        self.assertTrue(terminated(pid, pids['api']), 'fixture cleanup failed')

    def test_termination_reaps_inflight_api_and_terminates_descendant(self):
        self.exercise('interrupt')

    def test_real_timeout_terminates_descendant(self):
        self.exercise('timeout')

    def test_interrupt_oracle_rejects_direct_child_only_mutant(self):
        self.exercise('interrupt', mutant=True)

    def test_timeout_oracle_rejects_direct_child_only_mutant(self):
        self.exercise('timeout', mutant=True)


if __name__ == '__main__':
    unittest.main()
