#!/usr/bin/env python3
# catalog: tests — Verify private logout notification claims, per-provider local-day deduplication, concurrency, safe quoting, special-file refusal and fail-open delivery using synthetic fixtures.
"""Synthetic-only notification state, concurrency, delivery and privacy checks."""
import concurrent.futures
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'quotas-notify.sh'


class NotifyTests(unittest.TestCase):
    """Exercise delivery invariants with private fixtures and an injected adapter."""

    def setUp(self):
        """Create isolated report/state paths and avoid native OS notifications."""
        self.fixture = tempfile.TemporaryDirectory()
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        self.report = self.root / 'report.json'
        self.state = self.root / 'state.json'
        self.log = self.root / 'deliveries.jsonl'
        self.notify = self.root / 'notify'
        self.notify.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                               'with open(os.environ["FIXTURE_LOG"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n')
        self.notify.chmod(0o700)
        self.env = dict(os.environ, AI_QUOTAS_NOTIFY_STATE=str(self.state),
                        AI_QUOTAS_NOTIFY_DAY='2026-11-06', AI_QUOTAS_NOTIFY_BIN=str(self.notify),
                        FIXTURE_LOG=str(self.log))
        self.rows([('claude', 'same'), ('codex', 'same'), ('cursor', "O'Brien")])

    def rows(self, accounts, status='needs-login'):
        """Include untrusted extra fields to verify metadata-only delivery."""
        self.report.write_text(json.dumps({'rows': [dict(provider=p, label=l, status=status,
            detail='PRIVATE-SYNTHETIC-DETAIL', reported_email='UNUSED-EMAIL', action='UNTRUSTED-ACTION')
            for p, l in accounts]}))

    def run_helper(self):
        """Require the Bash entrypoint to remain silent and fail open."""
        result = subprocess.run(['/bin/bash', str(HELPER), str(self.report)], env=self.env,
                                capture_output=True, timeout=12)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b'')
        return result

    def deliveries(self):
        """Decode synthetic adapter calls, or report no attempts yet."""
        return [json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_daily_provider_isolation_and_private_state(self):
        """Claims are private, provider-qualified, and survive date revisits."""
        self.run_helper(); self.run_helper()
        self.assertEqual(len(self.deliveries()), 3)
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o600)
        self.env['AI_QUOTAS_NOTIFY_DAY'] = '2026-11-07'
        self.run_helper()
        self.assertEqual(len(self.deliveries()), 6)
        self.assertEqual(len(json.loads(self.state.read_text())), 6)
        self.env['AI_QUOTAS_NOTIFY_DAY'] = '2026-11-06'
        self.run_helper()
        self.env['AI_QUOTAS_NOTIFY_DAY'] = '2026-11-07'
        self.run_helper()
        self.assertEqual(len(self.deliveries()), 6)
        persisted = self.state.read_text() + self.log.read_text()
        for private in ('PRIVATE-SYNTHETIC-DETAIL', 'UNUSED-EMAIL', 'UNTRUSTED-ACTION'):
            self.assertNotIn(private, persisted)
        self.assertIn(['cursor', "O'Brien", 'open the Cursor IDE and sign in'], self.deliveries())

    def test_concurrent_claims(self):
        """Concurrent writers must publish one claim before one delivery."""
        self.rows([('codex', 'concurrent')])
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
            list(pool.map(lambda _: self.run_helper(), range(5)))
        self.assertEqual(len(self.deliveries()), 1)

    def test_bounded_date_window_rejects_clock_rollback(self):
        """Bound date retention without repeating an evicted day's attempt."""
        self.rows([('codex', 'clock')])
        for day in range(1, 10):
            self.env['AI_QUOTAS_NOTIFY_DAY'] = f'2026-11-{day:02d}'
            self.run_helper()
        self.assertEqual(len(json.loads(self.state.read_text())), 7)
        self.env['AI_QUOTAS_NOTIFY_DAY'] = '2026-11-01'
        self.run_helper()
        self.assertEqual(len(self.deliveries()), 9)

    def test_non_logout_empty_and_control_labels(self):
        """Only logged-out accounts with control-free labels can notify."""
        for status in ('ok', 'unreachable', 'unreadable', 'rate-limited'):
            self.rows([('claude', 'healthy')], status)
            self.run_helper()
        self.rows([('codex', 'bad\x1blabel')]); self.run_helper()
        self.assertEqual(self.deliveries(), [])

    def test_symlink_fifo_and_bad_state_refused(self):
        """Unsafe or corrupt destinations must remain untouched and silent."""
        sentinel = self.root / 'sentinel'; sentinel.write_text('untouched')
        self.state.symlink_to(sentinel); self.run_helper()
        self.assertEqual(sentinel.read_text(), 'untouched')
        self.state.unlink(); os.mkfifo(self.state); self.run_helper(); self.state.unlink()
        for content in ('broken', '{}', '[]\n[]', '[{"provider":"codex"}]'):
            self.state.write_text(content); self.run_helper()
            self.assertEqual(self.state.read_text(), content)
        self.assertEqual(self.deliveries(), [])

    def test_unsafe_lock_refused_and_no_temp_leak(self):
        """Special lock metadata must refuse promptly without temp orphans."""
        lock = Path(str(self.state) + '.lock')
        os.mkfifo(lock); self.run_helper(); lock.unlink()
        lock.mkdir(); os.mkfifo(lock / 'owner'); self.run_helper()
        self.assertEqual(self.deliveries(), [])
        self.assertEqual(list(self.root.glob('.quotas-notify.*')), [])

    def test_failure_claimed_before_delivery_and_quoted_label(self):
        """Safely derive actions and retain claims when delivery fails."""
        self.rows([('codex', "O'Brien ; $(echo never)")])
        self.run_helper()
        self.assertIn("'O'\\''Brien ; $(echo never)'", self.deliveries()[0][-1])
        self.env['AI_QUOTAS_NOTIFY_DAY'] = '2026-11-07'
        self.env['AI_QUOTAS_NOTIFY_BIN'] = '/usr/bin/false'
        self.run_helper()
        self.env['AI_QUOTAS_NOTIFY_BIN'] = str(self.notify)
        self.run_helper()
        self.assertEqual(len(self.deliveries()), 1)

    def test_option_shaped_label_uses_parser_separator(self):
        """Option-shaped labels stay literal arguments in generated commands."""
        self.rows([('codex', '--json')])
        self.run_helper()
        self.assertEqual(self.deliveries()[0][-1], '/quotas-setup relogin -- --json codex')


if __name__ == '__main__':
    unittest.main()
