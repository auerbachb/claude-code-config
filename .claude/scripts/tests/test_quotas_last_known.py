#!/usr/bin/env python3
# catalog: tests — Verify the last-known folder helper: locking and rereads, concurrent records, ordering refusal, owner upsert, identity validation, symlink and world-writable refusal, and private file modes, on synthetic fixtures only.
"""Synthetic-only checks for .claude/scripts/lib/quotas-last-known.py (issue #2280)."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor

HELPER = Path(__file__).resolve().parents[1] / 'lib' / 'quotas-last-known.py'
NOW = 1788897600


def run_helper(args, stdin=''):
    return subprocess.run([sys.executable, '-I', str(HELPER)] + args, input=stdin,
                          capture_output=True, text=True)


def account(provider, label, fetched, rows):
    return {'provider': provider, 'label': label, 'nickname': 'Nick', 'source': 'live: test',
            'fetched_at_epoch': fetched, 'fetched_at_et': 'fixture', 'rows': rows}


def row(window, pct, pool=None):
    return {'window': window, 'pool': pool, 'used_pct': pct, 'resets_at_epoch': NOW + 86400,
            'resets': 'fixture', 'overage': None}


class LastKnownTests(unittest.TestCase):

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory()
        self.addCleanup(self.fixture.cleanup)
        self.root = Path(self.fixture.name)
        self.folder = self.root / 'last-known'

    def record(self, accounts):
        return run_helper(['record', '--dir', str(self.folder)],
                          stdin=json.dumps({'accounts': accounts}))

    def load(self, name):
        return json.loads((self.folder / name).read_text())

    def test_record_writes_private_files_and_only_given_rows(self):
        result = self.record([account('claude', 'one@example.com', NOW, [row('7-day', 54)])])
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.folder / 'claude--one@example.com.json'
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.folder.stat().st_mode), 0o700)
        self.assertEqual(self.load(path.name)['rows'][0]['used_pct'], 54)

    def test_non_finite_and_figureless_rows_are_not_saved(self):
        rows = [row('7-day', 'NaN'), row('5-hour', None)]
        self.record([account('claude', 'one@example.com', NOW, rows)])
        self.assertFalse((self.folder / 'claude--one@example.com.json').exists())

    def test_partial_live_read_keeps_saved_series_it_did_not_read(self):
        # Cursor-style account: the live run reads only one pool ok; the other
        # pool's last good reading must survive the rewrite.
        self.record([account('cursor', 'c@example.com', NOW,
                             [row('cursor-models', 53, 'cursor-models'),
                              row('cursor-auto', 20, 'cursor-auto')])])
        result = self.record([account('cursor', 'c@example.com', NOW + 60,
                                      [row('cursor-models', 61, 'cursor-models')])])
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = {r['pool']: r for r in self.load('cursor--c@example.com.json')['rows']}
        self.assertEqual(set(rows), {'cursor-models', 'cursor-auto'})
        self.assertEqual(rows['cursor-models']['used_pct'], 61)
        self.assertEqual(rows['cursor-auto']['used_pct'], 20)
        self.assertEqual(rows['cursor-auto']['fetched_at_epoch'], NOW)

    def test_ordering_refuses_to_replace_a_newer_reading(self):
        self.record([account('codex', 'a@example.com', NOW + 3600, [row('7-day', 40)])])
        before = (self.folder / 'codex--a@example.com.json').read_bytes()
        result = self.record([account('codex', 'a@example.com', NOW, [row('7-day', 10)])])
        self.assertEqual(result.returncode, 0)
        self.assertIn('newer', result.stderr)
        self.assertEqual((self.folder / 'codex--a@example.com.json').read_bytes(), before)

    def test_owner_upsert_keeps_other_series(self):
        self.record([account('cursor', 'c@example.com', NOW,
                             [row('cursor-models', 53, 'cursor-models')])])
        result = run_helper(['owner-report', '--dir', str(self.folder), '--now', str(NOW + 5),
                             '--provider', 'cursor', '--label', 'c@example.com', '--nickname', 'Cursor',
                             '--window', 'other-models', '--pool', 'other-models', '--used-pct', '100',
                             '--resets-text', 'Nov 28 2026', '--now-et', 'fixture'])
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = {r['window']: r for r in self.load('cursor--c@example.com.json')['rows']}
        self.assertEqual(set(rows), {'cursor-models', 'other-models'})
        self.assertEqual(rows['other-models']['source'], 'owner-reported')
        self.assertEqual(rows['cursor-models']['used_pct'], 53)
        self.assertIsInstance(rows['other-models']['used_pct'], int)

    def test_lookup_never_writes_and_flags_expiry(self):
        self.record([account('claude', 'one@example.com', NOW - 100, [row('7-day', 90)])])
        before = {p.name: p.read_bytes() for p in self.folder.iterdir()}
        result = run_helper(['lookup', '--dir', str(self.folder), '--now', str(NOW + 10 * 86400)],
                            stdin='{"provider": "claude", "label": "one@example.com"}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        self.assertTrue(lines and lines[0]['expired'])
        self.assertEqual({p.name: p.read_bytes() for p in self.folder.iterdir()}, before)

    def test_stopgap_file_without_provenance_is_readable(self):
        self.folder.mkdir(mode=0o700)
        (self.folder / 'cursor--cursor-ultra.json').write_text(json.dumps({
            'provider': 'cursor', 'label': 'cursor-ultra', 'fetched_at_epoch': NOW,
            'source': 'owner-reported',
            'rows': [{'window': 'cursor-models', 'used_pct': 100, 'resets': 'Nov 28 2026'}]}))
        result = run_helper(['lookup', '--dir', str(self.folder), '--now', str(NOW)],
                            stdin='{"provider": "cursor", "label": "cursor-ultra"}\n')
        line = json.loads(result.stdout.splitlines()[0])
        self.assertEqual((line['pool'], line['used_pct'], line['source']),
                         ('cursor-models', 100, 'owner-reported'))

    def test_invalid_identity_is_refused_at_the_path_boundary(self):
        result = self.record([account('evil', 'x', NOW, [row('7-day', 1)]),
                              account('claude', '../escape', NOW, [row('7-day', 1)])])
        self.assertEqual(result.returncode, 0)
        self.assertFalse(any(self.folder.glob('*.json')) if self.folder.exists() else False)

    def test_symlinked_folder_is_refused(self):
        target = self.root / 'target'
        target.mkdir()
        self.folder.symlink_to(target, target_is_directory=True)
        result = self.record([account('claude', 'one@example.com', NOW, [row('7-day', 1)])])
        self.assertEqual(result.returncode, 5)
        self.assertEqual(list(target.iterdir()), [])

    def test_world_writable_folder_is_refused(self):
        self.folder.mkdir(mode=0o700)
        os.chmod(self.folder, 0o777)
        result = self.record([account('claude', 'one@example.com', NOW, [row('7-day', 1)])])
        self.assertEqual(result.returncode, 5)

    def test_concurrent_records_for_different_accounts_both_survive(self):
        def write(label):
            return self.record([account('codex', label, NOW, [row('7-day', 5)])]).returncode
        with ThreadPoolExecutor(max_workers=4) as pool:
            codes = list(pool.map(write, ['a@example.com', 'b@example.com', 'c@example.com', 'd@example.com']))
        self.assertTrue(all(code == 0 for code in codes))
        names = sorted(p.name for p in self.folder.glob('codex--*.json'))
        self.assertEqual(len(names), 4)

    def test_usage_errors_exit_three(self):
        result = run_helper(['owner-report', '--dir', str(self.folder), '--provider', 'claude',
                             '--label', 'one@example.com', '--window', '7-day', '--used-pct', '101'])
        self.assertEqual(result.returncode, 3)
        result = run_helper(['owner-report', '--dir', str(self.folder), '--provider', 'claude',
                             '--label', 'one@example.com', '--window', '7-day', '--used-pct', '5',
                             '--resets-text', '2026-02-31'])
        self.assertEqual(result.returncode, 3)


if __name__ == '__main__':
    unittest.main()
