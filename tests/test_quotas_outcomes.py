#!/usr/bin/env python3
"""Outcome ledger contract tests: retention, privacy, concurrency and statistics."""
import concurrent.futures
import contextlib
import datetime as dt
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('outcomes', Path(__file__).parents[1] / '.claude/scripts/lib/quotas-outcomes.py')
outcomes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(outcomes)
NOW = 1788897600


def row(days=0, status='logged_out', **extra):
    return dict(ts=dt.datetime.fromtimestamp(NOW - days * 86400, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                provider='claude', label='fixture', source='oauth-usage', status=status,
                error_class='credential_unavailable', **extra)


class Ledger(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = str(Path(self.tmp.name) / 'history.outcomes.jsonl')
        self.run = str(Path(self.tmp.name) / 'run.jsonl')

    def write(self, path, rows):
        Path(path).write_text(''.join(json.dumps(r) + '\n' for r in rows))

    def process(self, rows):
        self.write(self.run, rows)
        return outcomes.process(self.ledger, self.run, NOW)

    def test_streak_and_reset(self):
        self.assertEqual(self.process([row()])[0]['streak_count'], 1)
        self.assertEqual(self.process([row()])[0]['streak_count'], 2)
        stats = self.process([row(status='ok')])[0]
        self.assertEqual(stats['streak_count'], 0)
        self.assertEqual(stats['failures_7d'], 2)
        self.assertEqual(stats['attempts_7d'], 3)
        self.assertAlmostEqual(stats['failure_rate_7d'], 2/3)

    def test_windows_retention_and_malformed(self):
        self.write(self.ledger, [row(46), row(31), row(20), row(8, 'ok'), row(3), row(1, 'ok')])
        with open(self.ledger, 'a') as stream:
            stream.write('malformed\n42\n{}\n')
        stats = self.process([row()])[0]
        self.assertEqual((stats['attempts_7d'], stats['failures_7d']), (3, 2))
        self.assertEqual((stats['attempts_30d'], stats['failures_30d']), (5, 3))
        rows = [json.loads(line) for line in Path(self.ledger).read_text().splitlines()]
        self.assertEqual(len(rows), 6)
        self.assertEqual(Path(self.ledger).stat().st_mode & 0o777, 0o600)

    def test_private_fields_and_invalid_classes(self):
        self.process([row(secret='NEVER-PERSIST-THIS', detail='NEVER-PERSIST-THIS')])
        text = Path(self.ledger).read_text()
        self.assertNotIn('NEVER-PERSIST-THIS', text)
        invalid = row()
        invalid['error_class'] = 'unsafe/token'
        self.process([invalid])
        self.assertEqual(json.loads(Path(self.ledger).read_text().splitlines()[-1])['error_class'], 'other')
        self.process([row(status='ok')])
        self.assertIsNone(json.loads(Path(self.ledger).read_text().splitlines()[-1])['error_class'])

    def test_symlink_refused_and_stats_survive(self):
        target = Path(self.tmp.name) / 'target'
        target.write_text('untouched')
        Path(self.ledger).symlink_to(target)
        with contextlib.redirect_stderr(io.StringIO()):
            stats = self.process([row()])
        self.assertEqual(target.read_text(), 'untouched')
        self.assertEqual(stats[0]['streak_count'], 1)
        self.assertTrue(Path(self.ledger).is_symlink())

    def test_lock_symlink_refused(self):
        target = Path(self.tmp.name) / 'target'
        target.write_text('untouched')
        Path(self.ledger + '.lock').symlink_to(target)
        with contextlib.redirect_stderr(io.StringIO()):
            stats = self.process([row()])
        self.assertEqual(stats[0]['attempts_7d'], 1)
        self.assertEqual(target.read_text(), 'untouched')
        self.assertFalse(Path(self.ledger).exists())

    def test_concurrent_writers_preserve_attempts(self):
        runs = []
        for i in range(8):
            path = str(Path(self.tmp.name) / f'run-{i}')
            self.write(path, [row()])
            runs.append(path)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda run: outcomes.process(self.ledger, run, NOW), runs))
        self.assertEqual(len(Path(self.ledger).read_text().splitlines()), 8)

    def test_unreadable_existing_ledger_is_never_replaced(self):
        self.write(self.ledger, [row(1, 'ok')])
        before = Path(self.ledger).read_bytes()
        real_open = outcomes.os.open

        def guarded_open(path, flags, *args, **kwargs):
            if str(path) == self.ledger:
                raise PermissionError('simulated unreadable ledger')
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(outcomes.os, 'open', side_effect=guarded_open):
            with contextlib.redirect_stderr(io.StringIO()):
                stats = self.process([row()])
        self.assertEqual(Path(self.ledger).read_bytes(), before)
        self.assertEqual(stats[0]['attempts_7d'], 1)
        self.assertEqual(stats[0]['streak_count'], 1)

    def test_later_started_concurrent_run_is_not_lost(self):
        # A fast run started later and committed before this slow run finishes.
        later = row(-1, 'ok')
        self.write(self.ledger, [later])
        stats = self.process([row()])[0]
        saved = [json.loads(line) for line in Path(self.ledger).read_text().splitlines()]
        self.assertEqual(len(saved), 2)
        self.assertEqual(saved[0]['ts'], later['ts'])
        self.assertEqual(stats['attempts_7d'], 1)
        self.assertEqual(stats['streak_count'], 1)

    def test_disabled_persistence_still_returns_current(self):
        self.write(self.run, [row()])
        stats = outcomes.process('', self.run, NOW)
        self.assertEqual(stats[0]['attempts_7d'], 1)
        self.assertFalse(Path(self.ledger).exists())


if __name__ == '__main__':
    unittest.main()
