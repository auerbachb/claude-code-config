"""Exercise real FIFO waits and missing-fixture guards without provider access."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / '.claude/scripts/ai-quotas.sh').read_text()
FUNCTIONS = '\n'.join(re.search(r'^' + name + r'\(\).*?^}', SOURCE,
                                re.M | re.S)[0]
                      for name in ('codex_stop_server', 'codex_app_server_read'))
SHELLS = list(dict.fromkeys(filter(None, ('/bin/bash', shutil.which('bash')))))


class QuotaWaits(unittest.TestCase):
    def run_private(self, shell, body, server_mode='healthy'):
        with tempfile.TemporaryDirectory(prefix='quota-waits-') as td:
            tmp = Path(td)
            home = tmp / 'home'
            home.mkdir()
            binary = tmp / 'bin'
            binary.mkdir()
            hits = tmp / 'forbidden'
            for name in ('curl', 'security', 'claude', 'codex', 'cursor', 'node'):
                fake = binary / name
                fake.write_text('#!/bin/sh\necho boundary >> "$FORBIDDEN_HITS"\nexit 97\n')
                fake.chmod(0o700)
            for name in ('jq', 'python3', 'sqlite3'):
                target = shutil.which(name)
                self.assertIsNotNone(target)
                (binary / name).symlink_to(target)
            (binary / 'bash').symlink_to(shell)
            server = tmp / 'server'
            linger = ('while :; do /bin/sleep 0.2; done; '
                      if server_mode == 'ignore-term' else '')
            answer = ('case "$request" in *account/rateLimits/read*) '
                      'printf \'{"id" : 2,"result":{}}\\n\'; ' + linger + ';; esac\n')
            server.write_text('#!/bin/bash\n'
                              + ('trap "" TERM\n' if server_mode == 'ignore-term' else '')
                              + 'while IFS= read -r request; do\n'
                              + (answer if server_mode != 'silent' else ':\n')
                              + 'done\n')
            server.chmod(0o700)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('AI_QUOTAS_', 'CLAUDE_QUOTAS_', 'STUB_'))
                   and k not in ('BASH_ENV', 'ENV', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME')}
            env.update(HOME=str(home), PATH=str(binary) + ':/usr/bin:/bin',
                       FORBIDDEN_HITS=str(hits), AI_QUOTAS_NOTIFY_BIN='/usr/bin/true')
            for name in ('CURL', 'SECURITY', 'CLAUDE', 'CODEX'):
                env['AI_QUOTAS_' + name + '_BIN'] = str(binary / name.lower())
            command = ('set -uo pipefail\n' + FUNCTIONS
                       + '\nTMP="$1"; SERVER="$2"; ROOT="$3"; CODEX_TIMEOUT=1\n' + body)
            started = time.monotonic()
            proc = subprocess.Popen([shell, '-c', command, 'fixture', td, str(server),
                                     str(ROOT)], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
            try:
                stdout, stderr = proc.communicate(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                self.fail('private FIFO fixture exceeded its outer deadline')
            finally:
                # Only our owned process group; never signal an inferred provider PID.
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            self.assertFalse(hits.exists(), 'a real-command fallback was attempted')
            return proc.returncode, stdout, stderr, time.monotonic() - started

    def test_healthy_and_term_resistant_servers(self):
        for shell in SHELLS:
            for mode in ('healthy', 'ignore-term'):
                with self.subTest(shell=shell, mode=mode):
                    rc, out, err, elapsed = self.run_private(
                        shell, 'codex_app_server_read "$HOME" "$SERVER"; rc=$?; '
                        '[[ -z "$CODEX_FAIL_REASON" ]] || exit 91; '
                        'cat "$CODEX_RESULT_FILE"; exit "$rc"', mode)
                    self.assertEqual(rc, 0, err)
                    self.assertEqual(json.loads(out)['id'], 2)
                    self.assertLess(elapsed, 7)

    def test_nonresponsive_server_keeps_timeout_allowance(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                rc, out, err, elapsed = self.run_private(
                    shell, 'rc=0; codex_app_server_read "$HOME" "$SERVER" || rc=$?; '
                    'printf "%s:%s\\n" "$rc" "$CODEX_FAIL_REASON"', 'silent')
                self.assertEqual(rc, 0, err)
                self.assertIn('1:app-server did not answer within 1s', out)
                self.assertGreaterEqual(elapsed, 0.9)
                self.assertLess(elapsed, 7)

    def test_frozen_clock_has_finite_tick_fuse(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                rc, out, err, elapsed = self.run_private(
                    shell, 'unset SECONDS; SECONDS=0; rc=0; '
                    'codex_app_server_read "$HOME" "$SERVER" || rc=$?; '
                    'printf "%s\\n" "$rc"', 'silent')
                self.assertEqual(rc, 0, err)
                self.assertEqual(out.strip(), '1')
                self.assertGreaterEqual(elapsed, 0.9)
                self.assertLess(elapsed, 7)

    def test_missing_or_backward_clock_fails_honestly(self):
        for shell in SHELLS:
            for change in ('unset SECONDS', 'SECONDS=0'):
                with self.subTest(shell=shell, change=change):
                    rc, out, err, elapsed = self.run_private(
                        shell, 'SECONDS=100; grep() { ' + change + '; command grep "$@"; }; '
                        'rc=0; codex_app_server_read "$HOME" "$SERVER" || rc=$?; '
                        'printf "%s:%s\\n" "$rc" "$CODEX_FAIL_REASON"', 'silent')
                    self.assertEqual(rc, 0, err)
                    self.assertIn('1:app-server response clock unavailable', out)
                    self.assertLess(elapsed, 7)

    def test_invalid_pid_never_reaches_kill(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                rc, out, err, _ = self.run_private(
                    shell, 'kill() { echo called; }; '
                    'for pid in 0 -1 invalid "$$"; do '
                    'codex_stop_server "$pid" && exit 91; done; echo guarded')
                self.assertEqual(rc, 0, err)
                self.assertEqual(out.strip(), 'guarded')

    def test_missing_fake_fails_before_reader_launch(self):
        for shell in SHELLS:
            for fake in ('curl', 'security', 'codex', 'claude'):
                with self.subTest(shell=shell, fake=fake):
                    rc, _, err, _ = self.run_private(
                        shell, 'source "$ROOT/.claude/scripts/tests/lib/ai-quotas-fixtures.bash"; '
                        'rm -f "$BIN/' + fake + '"; run --json; exit 91')
                    self.assertEqual(rc, 1)
                    self.assertIn('missing required fake: ' + fake, err)


if __name__ == '__main__':
    unittest.main()
