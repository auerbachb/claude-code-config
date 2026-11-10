"""Real estimate CLI deduplication with private ledgers and synthetic GitHub."""
import json
import shutil
import subprocess
import unittest

import test_estimate_log_locks as fixtures


class EstimateDedupTests(unittest.TestCase):
    def setUp(self):
        # Compose the existing fixture; importing its module does not rediscover
        # the lock TestCase or run its independent process-race controls twice.
        self.f = fixtures.EstimateLockTests('test_append_backfill_rounds_patch_and_rollup')
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.assertEqual(self.f.finish(self.f.start(101)), '')
        self.row = json.loads(self.f.log.read_text())

    def encoded(self, row, style='compact'):
        if style == 'spaces':
            return ('  ' + json.dumps(row) + '  \n').encode()
        if style == 'tabs-crlf':
            return ('\t' + json.dumps(row, separators=('\t,\t', '\t:\t')) + '\t\r\n').encode()
        return (json.dumps(row, separators=(',', ':')) + '\n').encode()

    def append(self, number=101):
        self.assertEqual(self.f.finish(self.f.start(number)), '')

    def command(self, *arguments):
        return subprocess.run([fixtures.SHELL, str(self.f.script), *arguments],
                              env=self.f.env, capture_output=True, text=True, timeout=15)

    def test_matching_rows_keep_bytes_across_formats_and_neighbor_positions(self):
        neighbors = {
            'foreign': self.encoded(dict(self.row, repo='other/repository')),
            'other-pr': self.encoded(dict(self.row, pr=1101)),
            'malformed': b'{not-json\n',
            'nonobjects': b'null\n[]\n"text"\n101\ntrue\n',
        }
        for style in ('compact', 'spaces', 'tabs-crlf'):
            target = self.encoded(self.row, style)
            for name, neighbor in neighbors.items():
                for position in ('before', 'after'):
                    with self.subTest(style=style, neighbor=name, position=position):
                        before = target + neighbor if position == 'before' else neighbor + target
                        self.f.log.write_bytes(before)
                        self.append()
                        self.append()
                        self.assertEqual(self.f.log.read_bytes(), before)
            with self.subTest(style=style, final_newline=False):
                before = neighbors['foreign'] + target.rstrip(b'\n')
                self.f.log.write_bytes(before)
                self.append()
                self.assertEqual(self.f.log.read_bytes(), before)

    def test_nonmatching_rows_do_not_suppress_a_real_append(self):
        prefixes = {
            'empty': b'',
            'foreign': self.encoded(dict(self.row, repo='other/repository'), 'spaces'),
            'repo-prefix': self.encoded(dict(self.row, repo='acme/widgets-extra')),
            'pr-prefix': self.encoded(dict(self.row, pr=1101)),
            'string-pr': self.encoded(dict(self.row, pr='101')),
            'nested': (json.dumps([self.row]) + '\n').encode(),
            'malformed': b'not-json\n',
        }
        for name, prefix in prefixes.items():
            with self.subTest(prefix=name):
                self.f.log.write_bytes(prefix)
                self.append()
                after = self.f.log.read_bytes()
                self.assertTrue(after.startswith(prefix))
                appended = json.loads(after[len(prefix):])
                self.assertEqual((appended['repo'], appended['pr']), ('acme/widgets', 101))
                self.append()
                self.assertEqual(self.f.log.read_bytes(), after)

    def test_backfill_reproduction_repeats_and_preserves_siblings_and_rollup(self):
        target = dict(self.row, rounds=None)
        foreign = dict(self.row, repo='other/repository', rounds=9, actual_min=9999)
        foreign_bytes = self.encoded(foreign, 'spaces')
        malformed = b'not-json\n'
        for position in ('before', 'after'):
            with self.subTest(neighbors=position):
                neighbor = foreign_bytes + malformed
                target_bytes = self.encoded(target, 'spaces')
                self.f.log.write_bytes(neighbor + target_bytes if position == 'before'
                                       else target_bytes + neighbor)
                result = self.command('--backfill', '--repo', 'acme/widgets', '--limit', '2')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('WARN', result.stderr)
                after = self.f.log.read_bytes()
                rows = [json.loads(line) for line in after.splitlines() if line != b'not-json']
                ours = [row for row in rows if row['repo'] == 'acme/widgets']
                self.assertEqual(sorted(row['pr'] for row in ours), [101, 102])
                self.assertTrue(all(row['rounds'] == 2 for row in ours))
                self.assertIn(foreign_bytes, after)
                self.assertIn(malformed, after)
                self.assertIn(foreign, rows)
                result = self.command('--backfill', '--repo', 'acme/widgets', '--limit', '2')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('WARN', result.stderr)
                self.append()
                self.append(102)
                self.assertEqual(self.f.log.read_bytes(), after)
                report = self.f.root / 'rollup.md'
                result = self.command('--rollup', '--repo', 'acme/widgets', '--output', str(report))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('(2 rows)', result.stderr)
                self.assertIn('acme/widgets', report.read_text())
                self.assertNotIn('other/repository', report.read_text())
                self.assertEqual(self.f.log.read_bytes(), after)

    def test_under_lock_recheck_observes_a_row_arriving_after_the_first_check(self):
        real_mkdir = shutil.which('mkdir')
        for matching in (True, False):
            with self.subTest(matching=matching):
                row = self.row if matching else dict(self.row, repo='other/repository')
                expected = self.encoded(row, 'spaces')
                self.f.log.unlink()
                inject = self.f.root / 'inject-row'
                inject.write_bytes(expected)
                marker = self.f.root / 'injected'
                marker.unlink(missing_ok=True)
                # The first check sees no log. Publish a completed predecessor's
                # row at the actual mkdir boundary, before the under-lock check.
                self.f.tool('mkdir', '''import os,sys
from pathlib import Path
log=Path(os.environ['ESTIMATE_LOG_FILE'])
root=Path(os.environ['LOCK_FIXTURE'])
if sys.argv[1:]==[str(log)+'.lock'] and not (root/'injected').exists():
 os.mkdir(str(log)+'.lock')
 log.write_bytes((root/'inject-row').read_bytes())
 (root/'injected').touch()
else:
 os.execv(''' + repr(real_mkdir) + ''', [''' + repr(real_mkdir) + ''']+sys.argv[1:])
''')
                self.append()
                self.assertTrue(marker.exists())
                self.assertFalse(self.f.lock.exists())
                after = self.f.log.read_bytes()
                if matching:
                    self.assertEqual(after, expected)
                else:
                    self.assertTrue(after.startswith(expected))
                    appended = json.loads(after[len(expected):])
                    self.assertEqual((appended['repo'], appended['pr']), ('acme/widgets', 101))


if __name__ == '__main__':
    unittest.main()
