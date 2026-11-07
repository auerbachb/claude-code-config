"""Exercise interruption cleanup in the real read-only invitation CLI."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


class InvitationInterruptionTest(unittest.TestCase):
    def test_termination_reaps_inflight_api_process(self):
        helper = Path(__file__).resolve().parents[1] / '.claude/scripts/lib/bugbot_invitation.py'
        with tempfile.TemporaryDirectory(prefix='invitation-interrupt-fixture-') as directory:
            root = Path(directory)
            binary = root / 'gh'
            pid_file = root / 'api.pid'
            binary.write_text('#!/bin/sh\nprintf "%s\\n" "$$" > "$GH_FIXTURE_PID"\nsleep 30\n')
            binary.chmod(0o755)
            env = dict(os.environ, HOME=str(root), TMPDIR=str(root),
                       PATH=str(root) + os.pathsep + os.environ['PATH'],
                       GH_FIXTURE_PID=str(pid_file))
            proc = subprocess.Popen([sys.executable, str(helper), '--repo', 'fixture/repo',
                                     '--pr', '7', '--head', 'a' * 40],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
            api_pid = None
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(pid_file.exists(), 'the real API subprocess must have started')
                api_pid = int(pid_file.read_text().strip())
                proc.send_signal(signal.SIGTERM)
                stdout, stderr = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, 130, stderr.decode())
                self.assertEqual(stdout, b'', 'interruption cannot emit a clean decision')
                with self.assertRaises(ProcessLookupError):
                    os.kill(api_pid, 0)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate(timeout=5)
                if api_pid is not None:
                    try:
                        os.killpg(api_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass


if __name__ == '__main__':
    unittest.main()
