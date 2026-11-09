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
                      for name in ('codex_supervise_server', 'codex_stop_server',
                                   'codex_app_server_read'))
def supported_shells():
    candidates = ('/bin/bash', os.environ.get('QUOTAS_WAITS_CURRENT_BASH'),
                  shutil.which('bash'), '/opt/homebrew/bin/bash', '/usr/local/bin/bash')
    shells = []
    for candidate in filter(None, candidates):
        path = Path(candidate)
        if not path.is_file() or not os.access(path, os.X_OK):
            continue
        resolved = str(path.resolve())
        if resolved not in shells:
            shells.append(resolved)
    if not shells:
        raise RuntimeError('no executable Bash fixture shell')
    return shells


SHELLS = supported_shells()


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
            linger = ('exec /bin/sleep 10; ' if server_mode == 'ignore-term'
                      else 'exit 0; ' if server_mode == 'exited-descendant' else '')
            answer = ('case "$request" in *account/rateLimits/read*) '
                      'printf \'{"id" : 2,"result":{}}\\n\'; ' + linger + ';; esac\n')
            descendant = (
                '(trap "" TERM; printf "%s\\n" ready > "$DESCENDANT_READY_FILE"; '
                'exec /bin/sleep 10) </dev/null >/dev/null 2>&1 &\n'
                'printf "%s\\n" "$!" > "$DESCENDANT_PID_FILE"\n'
                'for i in {1..60}; do [[ -s "$DESCENDANT_READY_FILE" ]] && break; '
                '/bin/sleep .02; done\n'
                if server_mode in ('descendant', 'exited-descendant', 'exited-silent-descendant') else '')
            server.write_text('#!/bin/bash\nprintf \'%s\\n\' \"$$\" > \"$SERVER_PID_FILE\"\n'
                              + ('trap "" TERM\n' if server_mode == 'ignore-term' else '')
                              + descendant
                              + ('exit 0\n' if server_mode == 'exited-silent-descendant' else '')
                              + 'while IFS= read -r request; do\n'
                              + (answer if server_mode != 'silent' else ':\n')
                              + 'done\n')
            server.chmod(0o700)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('AI_QUOTAS_', 'CLAUDE_QUOTAS_', 'STUB_'))
                   and k not in ('BASH_ENV', 'ENV', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME')}
            env.update(HOME=str(home), PATH=str(binary) + ':/usr/bin:/bin',
                       FORBIDDEN_HITS=str(hits), SERVER_PID_FILE=str(tmp / 'server.pid'),
                       DESCENDANT_PID_FILE=str(tmp / 'descendant.pid'),
                       DESCENDANT_READY_FILE=str(tmp / 'descendant.ready'),
                       AI_QUOTAS_NOTIFY_BIN='/usr/bin/true')
            for name in ('CURL', 'SECURITY', 'CLAUDE', 'CODEX'):
                env['AI_QUOTAS_' + name + '_BIN'] = str(binary / name.lower())
            command = ('set -uo pipefail\nwarn() { printf "%s\\n" "$*" >&2; }\n' + FUNCTIONS
                       + '\nTMP="$1"; SERVER="$2"; ROOT="$3"; CODEX_TIMEOUT=1\n' + body)
            started = time.monotonic()
            proc = subprocess.Popen([shell, '-c', command, 'fixture', td, str(server),
                                     str(ROOT)], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    start_new_session=True)
            try:
                stdout, stderr = proc.communicate(timeout=12)
                # Check the reader's cleanup before our unconditional safety teardown.
                for name in ('server.pid', 'descendant.pid'):
                    pid_file = tmp / name
                    if not pid_file.exists():
                        continue
                    pid = int(pid_file.read_text().strip())
                    # An orphaned zombie is dead and awaits the OS reaper.
                    state = subprocess.run(
                        ['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True,
                        text=True, check=False).stdout.strip()
                    self.assertTrue(not state or state.startswith('Z'),
                                    f'reader left {name} alive before fixture teardown')
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.communicate()
                self.fail('private FIFO fixture exceeded its outer deadline')
            finally:
                # Only touch processes proven to belong to the test session.
                # The stub records each finite-lived fixture it actually starts.
                for name in ('server.pid', 'descendant.pid'):
                    pid_file = tmp / name
                    if not pid_file.exists():
                        continue
                    try:
                        pid = int(pid_file.read_text().strip())
                        if os.getsid(pid) == proc.pid:
                            os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
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
                    self.assertNotIn('Killed', err)
                    self.assertLess(elapsed, 7)

    def test_term_resistant_descendant_and_unrelated_process(self):
        for shell in SHELLS:
            for mode in ('descendant', 'exited-descendant'):
                with self.subTest(shell=shell, mode=mode):
                    rc, out, err, elapsed = self.run_private(
                        shell, '/bin/sleep 10 >/dev/null 2>&1 & other=$!; '
                        'trap \'kill "$other" 2>/dev/null; wait "$other" 2>/dev/null\' EXIT; '
                        'codex_app_server_read "$HOME" "$SERVER" || exit 91; '
                        'kill -0 "$other" || exit 92; '
                        '[[ -s "$DESCENDANT_PID_FILE" && ! -p "$TMP/codex.fifo" ]] || exit 93; '
                        'cat "$CODEX_RESULT_FILE"', mode)
                    self.assertEqual(rc, 0, err)
                    self.assertEqual(json.loads(out)['id'], 2)
                    self.assertLess(elapsed, 7)

    def test_cleanup_observes_members_after_supervisor_exit(self):
        # A finite-lived member in a real isolated group models a signal
        # whose target has not exited yet. The supervisor exits immediately.
        body = r'''
control="$TMP/group-observation"
mkdir "$control" || exit 91
set -m
(
  set +m
  /bin/sleep 1.5 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$DESCENDANT_PID_FILE"
  for i in {1..100}; do
    [[ ! -e "$control/shutdown.request" ]] || exit 0
    /bin/sleep .02
  done
) >/dev/null 2>&1 &
owner=$!
set +m
for i in {1..100}; do
  [[ ! -s "$DESCENDANT_PID_FILE" ]] || break
  /bin/sleep .02
done
IFS= read -r leaf < "$DESCENDANT_PID_FILE" || exit 92
group="$(ps -o pgid= -p "$leaf" | tr -d '[:space:]')"
[[ "$group" == "$owner" ]] || exit 93
: > "$control/owned" || exit 94
codex_stop_server "$owner" "$control" 2>/dev/null || exit 95
state="$(ps -o stat= -p "$leaf" 2>/dev/null | tr -d '[:space:]' || true)"
[[ -z "$state" || "$state" == Z* ]] || exit 96
echo group-exited
'''
        for shell in SHELLS:
            with self.subTest(shell=shell):
                rc, out, err, elapsed = self.run_private(shell, body)
                self.assertEqual(rc, 0, err)
                self.assertEqual(out.strip(), 'group-exited')
                self.assertLess(elapsed, 7)

    def test_exited_server_without_reply_leaves_no_descendant(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                rc, out, err, elapsed = self.run_private(
                    shell, 'if codex_app_server_read "$HOME" "$SERVER"; then exit 91; fi; '
                    '[[ -s "$DESCENDANT_PID_FILE" && ! -p "$TMP/codex.fifo" ]] || exit 92; '
                    'printf "%s\\n" "$CODEX_FAIL_REASON"', 'exited-silent-descendant')
                self.assertEqual(rc, 0, err)
                self.assertIn('app-server exited without answering', out)
                self.assertLess(elapsed, 7)

    def test_inherited_group_starts_no_provider(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                rc, out, err, elapsed = self.run_private(
                    shell, 'set() { [[ "$1" == -m ]] || builtin set "$@"; }; '
                    'if codex_app_server_read "$HOME" "$SERVER"; then exit 91; fi; '
                    '[[ ! -e "$SERVER_PID_FILE" && ! -p "$TMP/codex.fifo" ]] || exit 92; '
                    'printf "%s\\n" "$CODEX_FAIL_REASON"')
                self.assertEqual(rc, 0, err)
                self.assertIn('could not establish app-server process ownership', out)
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
                    'codex_stop_server "$pid" "$TMP" && exit 91; done; '
                    '[[ ! -e "$TMP/shutdown.request" ]] || exit 92; echo guarded')
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
