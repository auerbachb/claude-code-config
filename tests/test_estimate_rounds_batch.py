"""Real backfill CLI: batched replacement, counters, and lost-write controls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path(os.environ.get('ESTIMATE_BATCH_TEST_SOURCE', ROOT / '.claude/scripts/estimate-log.sh'))
SHELL = os.environ.get('ESTIMATE_BATCH_TEST_SHELL', 'bash')


class EstimateRoundsBatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='estimate-rounds-batch-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.log = self.root / 'ledger.jsonl'
        self.events = self.root / 'events'
        self.script = self.root / 'estimate-log.sh'
        shutil.copy2(SOURCE, self.script)
        self.env = dict(os.environ, HOME=str(self.home), ESTIMATE_LOG_FILE=str(self.log),
                        PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        BATCH_FIXTURE=str(self.root), BATCH_FAULT='',
                        BATCH_FAILURES='{}', BATCH_LATE='')
        for name in ('gh', 'mkdir', 'mv', 'cksum', 'grep', 'jq', 'mktemp'):
            real = shutil.which(name)
            self.env['BATCH_REAL_' + name.upper()] = real or ''
            path = self.bin / name
            path.write_text('#!' + sys.executable + '\n' + r'''
import json,os,sys
from pathlib import Path
name=Path(sys.argv[0]).name; args=sys.argv[1:]; root=Path(os.environ['BATCH_FIXTURE'])
log=root/'ledger.jsonl'; lock=Path(str(log)+'.lock'); fault=os.environ['BATCH_FAULT']
def event(s):
 with (root/'events').open('a') as f:f.write(s+'\n')
if name=='gh':
 if args[:2]==['pr','list']:print('[]');sys.exit(0)
 if args[0]=='api':
  pr=args[1].rsplit('/',1)[-1];event('api '+pr)
  failure=json.loads(os.environ['BATCH_FAILURES']).get(pr)
  if failure=='failed-positive':print(9);sys.exit(1)
  if failure is not None:
   if failure=='error':sys.exit(1)
   print(failure);sys.exit(0)
  if pr=='103' and os.environ['BATCH_LATE']:
   mode=os.environ['BATCH_LATE'];rows=[json.loads(x) for x in log.read_text().splitlines()]
   if mode=='measured':rows[0]['rounds']=88
   if mode=='removed':rows=rows[1:]
   if mode=='all-measured':
    for r in rows:r['rounds']=88
   if mode=='append':rows.append(dict(repo='acme/widgets',pr=999,rounds=7))
   log.write_text(''.join(json.dumps(r)+'\n' for r in rows))
  print(int(pr)%10+1);sys.exit(0)
 sys.exit(99)
if name=='mkdir' and args==[str(lock)]:event('lock')
if name=='mv' and args[-1:]==[str(log)]:
 event('replace')
 if fault=='rename':sys.exit(1)
if name=='mktemp' and any('.estimate-log-tmp-' in a for a in args) and fault=='allocate':sys.exit(1)
if name=='mktemp' and any('.estimate-rounds-batch-' in a for a in args) and fault=='allocate-map':sys.exit(1)
if name=='mktemp' and any('.estimate-rounds-matched-' in a for a in args) and fault=='allocate-matched':sys.exit(1)
if name=='jq' and '--slurpfile' in args and 'patches' in args:event('transform')
if name=='jq' and '--slurpfile' in args and 'patches' in args and fault=='render':sys.exit(4)
if name=='cksum':
 counter=root/'checksum-count';n=int(counter.read_text())+1 if counter.exists() else 1;counter.write_text(str(n))
 if n==2:
  if fault=='append':
   with log.open('a') as f:f.write('{"repo":"acme/widgets","pr":999,"rounds":7}\n')
  if fault=='ownership':(lock/'token').write_text('foreign-owner\n')
  if fault=='unreadable':sys.exit(1)
if name=='grep' and args[:2]==['-c',''] and any('.estimate-log-tmp-' in a for a in args) and fault=='row-count':
 print(0);sys.exit(0)
os.execv(os.environ['BATCH_REAL_'+name.upper()],[os.environ['BATCH_REAL_'+name.upper()]]+args)
''')
            path.chmod(0o700)

    def rows(self, count=3):
        rows = [dict(repo='acme/widgets', pr=101+i, rounds=None, keep={'n': i}) for i in range(count)]
        self.log.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        return rows

    def run_cli(self, **env):
        command = [SHELL, str(self.script), '--backfill', '--repo', 'acme/widgets', '--limit', '1']
        if env.get('BATCH_FAULT') in ('write', 'map-write'):
            command = [SHELL, '-c', r'''printf() {
  if [[ "$BATCH_FAULT" == map-write && "$1" == '%s' && "${2:-}" == '{"101":'* ]]; then
    return 99
  fi
  if [[ "$BATCH_FAULT" == write && "$1" == '%s\n' && "${2:-}" == *'"rounds":2'* && "${2:-}" == *'"keep":'* ]]; then
    return 99
  fi
  builtin printf "$@"
}
export -f printf
exec "$@"
''', '_'] + command
        p = subprocess.run(command,
                           env=dict(self.env, **env), cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, '')
        self.assertEqual(list(self.root.glob('.estimate-*-*')), [])
        return p.stderr

    def event_count(self, value):
        return self.events.read_text().splitlines().count(value) if self.events.exists() else 0

    def test_multiple_rows_one_lock_one_replacement(self):
        self.rows()
        out = self.run_cli()
        self.assertIn('appended=0 skipped=0 patched=3 patch_failed=0 failed=0', out)
        self.assertEqual([r['rounds'] for r in map(json.loads, self.log.read_text().splitlines())], [2, 3, 4])
        self.assertEqual(self.event_count('lock'), 1)
        self.assertEqual(self.event_count('replace'), 1)
        self.assertEqual(self.event_count('transform'), 1)
        self.assertEqual(self.events.read_text().splitlines()[:3], ['api 101', 'api 102', 'api 103'])

    def test_large_batch_is_one_replacement(self):
        self.rows(12)
        self.run_cli()
        self.assertEqual(self.event_count('lock'), 1)
        self.assertEqual(self.event_count('replace'), 1)

    def test_api_failure_does_not_abort_other_rows(self):
        self.rows()
        out = self.run_cli(BATCH_FAILURES='{"102":"error"}')
        self.assertIn('patched=2 patch_failed=1 failed=0', out)
        self.assertIn('could not patch rounds for PR #102', out)
        self.assertIsNone(json.loads(self.log.read_text().splitlines()[1])['rounds'])
        self.assertEqual(self.event_count('replace'), 1)

    def test_nonzero_api_with_positive_stdout_is_still_failure(self):
        self.rows()
        out = self.run_cli(BATCH_FAILURES='{"102":"failed-positive"}')
        self.assertIn('patched=2 patch_failed=1 failed=0', out)
        self.assertIsNone(json.loads(self.log.read_text().splitlines()[1])['rounds'])

    def test_all_invalid_api_values_do_not_lock(self):
        self.rows()
        before = self.log.read_bytes()
        out = self.run_cli(BATCH_FAILURES='{"101":"0","102":"null","103":"bad"}')
        self.assertIn('patched=0 patch_failed=3 failed=0', out)
        self.assertEqual(self.log.read_bytes(), before)
        self.assertEqual(self.event_count('lock'), 0)

    def test_duplicate_rows_count_one_pr(self):
        rows = self.rows()
        with self.log.open('a') as f:f.write(json.dumps(rows[0])+'\n')
        out = self.run_cli()
        self.assertIn('patched=3 patch_failed=0', out)
        self.assertEqual(len(self.log.read_text().splitlines()), 4)
        self.assertEqual(self.event_count('api 101'), 1)

    def test_measured_foreign_and_malformed_rows_preserved(self):
        self.rows()
        suffix = 'not json\n\n  {"repo":"foreign/repo", "pr":101, "rounds":null}\n{"repo":"acme/widgets", "pr":104,"rounds":77}\n'
        with self.log.open('a') as f:f.write(suffix)
        out = self.run_cli()
        self.assertTrue(self.log.read_text().endswith(suffix))
        self.assertIn('patched=3 patch_failed=0', out)

    def test_final_line_without_newline_is_not_lost(self):
        self.rows()
        self.log.write_bytes(self.log.read_bytes().rstrip(b'\n'))
        self.run_cli()
        self.assertEqual(len(self.log.read_text().splitlines()), 3)
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])['rounds'], 4)

    def test_second_run_is_noop(self):
        self.rows()
        self.run_cli()
        before = self.log.read_bytes()
        out = self.run_cli()
        self.assertIn('patched=0 patch_failed=0 failed=0', out)
        self.assertEqual(self.log.read_bytes(), before)
        self.assertEqual(self.event_count('lock'), 1)

    def test_missing_ledger_does_not_lock(self):
        self.run_cli()
        self.assertFalse(self.log.exists())
        self.assertEqual(self.event_count('lock'), 0)

    def test_fences_and_failures_leave_all_candidates_uncommitted(self):
        for fault in ('allocate', 'allocate-map', 'allocate-matched', 'map-write', 'render', 'write', 'row-count', 'unreadable', 'rename'):
            with self.subTest(fault=fault):
                self.rows()
                before = self.log.read_bytes()
                (self.root/'checksum-count').unlink(missing_ok=True)
                out = self.run_cli(BATCH_FAULT=fault)
                self.assertIn('patched=0 patch_failed=3 failed=0', out)
                self.assertEqual(self.log.read_bytes(), before)
                self.assertFalse(Path(str(self.log)+'.lock').exists())

    def test_concurrent_append_is_retained_and_batch_refuses(self):
        self.rows()
        before = self.log.read_bytes()
        out = self.run_cli(BATCH_FAULT='append')
        self.assertIn('patched=0 patch_failed=3 failed=0', out)
        self.assertTrue(self.log.read_bytes().startswith(before))
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])['pr'], 999)
        self.assertEqual(self.event_count('replace'), 0)

    def test_lost_lock_is_retained_and_batch_refuses(self):
        self.rows()
        before = self.log.read_bytes()
        out = self.run_cli(BATCH_FAULT='ownership')
        self.assertIn('patched=0 patch_failed=3 failed=0', out)
        self.assertEqual(self.log.read_bytes(), before)
        self.assertEqual(Path(str(self.log)+'.lock/token').read_text(), 'foreign-owner\n')
        self.assertEqual(self.event_count('replace'), 0)

    def test_collection_races_use_latest_ledger(self):
        for mode, expected in [('measured', 'patched=2 patch_failed=1'), ('removed', 'patched=2 patch_failed=1'),
                               ('all-measured', 'patched=0 patch_failed=3'), ('append', 'patched=3 patch_failed=0')]:
            with self.subTest(mode=mode):
                self.rows()
                (self.root/'checksum-count').unlink(missing_ok=True)
                out = self.run_cli(BATCH_LATE=mode)
                self.assertIn(expected, out)
                rows = list(map(json.loads, self.log.read_text().splitlines()))
                if mode in ('measured', 'all-measured'):self.assertEqual(rows[0]['rounds'], 88)
                if mode == 'removed':self.assertNotIn(101, [r['pr'] for r in rows])
                if mode == 'append':self.assertEqual(rows[-1]['pr'], 999)

    def test_unselected_invalid_utf8_bytes_are_preserved(self):
        self.rows()
        suffix = b'bad-\xff-record\n{"repo":"foreign/repo","pr":88,"rounds":null,"note":"\xff"}\n' + b'null\nfalse\n[]\n"string"\n'
        with self.log.open('ab') as f:f.write(suffix)
        out = self.run_cli()
        self.assertIn('patched=3 patch_failed=0', out)
        self.assertTrue(self.log.read_bytes().endswith(suffix), self.log.read_bytes())

    def test_large_native_writer_map_does_not_become_an_os_argument(self):
        self.rows()
        # Execute the actual published function definitions, stopping before
        # argument parsing. No replica of the writer or its safety checks.
        source = self.script.read_text()
        marker = '# Argument parsing'
        self.assertEqual(source.count(marker), 1)
        definitions = self.root / 'writer-definitions.sh'
        definitions.write_text(source[:source.index(marker)])
        batch = self.root / 'large-batch.json'
        argument_limit = os.sysconf('SC_ARG_MAX')
        self.assertGreater(argument_limit, 0)
        count = argument_limit // 8 + 10000
        batch.write_text(json.dumps({str(n): 2 for n in range(1, count + 1)}, separators=(',', ':')))
        self.assertGreater(batch.stat().st_size, argument_limit)
        command = [SHELL, '-c', r'''source "$1"
batch=$(cat "$2")
rc=0
patch_rows_rounds acme/widgets "$batch" || rc=$?
printf 'BATCH_RESULT=%s\n' "$rc"
exit "$rc"
''', '_', str(definitions), str(batch)]
        p = subprocess.run(command, env=self.env, cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('BATCH_RESULT=0', p.stdout)
        self.assertEqual([r['rounds'] for r in map(json.loads, self.log.read_text().splitlines())], [2, 2, 2])
        self.assertEqual(self.event_count('lock'), 1)
        self.assertEqual(self.event_count('replace'), 1)
        self.assertEqual(list(self.root.glob('.estimate-*-*')), [])


if __name__ == '__main__':
    unittest.main()
