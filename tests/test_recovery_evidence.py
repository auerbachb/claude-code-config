"""Execute actual recovery fences against real scoped, locked state helpers."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def fence(file, anchor):
    return (ROOT/file).read_text().split('<!-- test-anchor: '+anchor+' -->', 1)[1].split('```bash\n', 1)[1].split('\n```', 1)[0]


class RecoveryEvidenceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='recovery-evidence-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        scripts = ROOT/'.claude/scripts'
        self.helper = scripts/'recovery-evidence.sh'
        self.session = scripts/'session-state.sh'
        self.handoff = scripts/'handoff-state.sh'
        self.env = dict(os.environ, HOME=str(self.home), CLAUDE_SESSION_REPO='wrong/repo',
                        CURRENT_REPO='fixture/repo', OWNER_REPO='fixture/repo', PR_NUM='7', PR_NUMBER='7',
                        WATCH_SHA='a'*40, WAIT_BASELINE='2026-11-07T17:00:00Z',
                        WRAP_RECOVERY_AUDIT='cycle1: failed gate\ncycle2: recover',
                        WRAP_AUDIT_STATE_SH=str(self.session), HANDOFF_STATE_SH=str(self.handoff),
                        RECOVERY_EVIDENCE_SH=str(self.helper), WAIT_EVAL_RC='0', WAIT_FETCH_RC='0')
        for name in ('CLAUDE_SESSION_STATE_FILE', 'CLAUDE_HANDOFF_ROOT', 'WAIT_CAPTURE_DIR', 'WRAP_GATE_CAPTURE'):
            self.env.pop(name, None)
        self.invoke([self.handoff, '--owner-repo', 'fixture/repo', '--init', '7', '{}'])
        self.wrap_capture = fence('.claude/skills/wrap/SKILL.md', 'wrap-capture-gate')
        self.wrap_save = fence('.claude/skills/wrap/SKILL.md', 'wrap-persist-recovery-audit')
        self.wait_functions = fence('.claude/skills/fixpr/SKILL.md', 'fixpr-persist-wait-evidence')
        self.stub = self.home/'command'
        self.stub.write_text('''#!/bin/sh
cat "$FIXTURE_OUT"
cat "$FIXTURE_ERR" >&2
exit "$FIXTURE_EXIT"
''')
        self.stub.chmod(0o755)
        self.out, self.err = self.home/'command.out', self.home/'command.err'
        self.err.write_bytes(b'fixture execution stderr\n')
        self.env.update(MERGE_GATE_SH=str(self.stub), FIXTURE_OUT=str(self.out), FIXTURE_ERR=str(self.err))

    def invoke(self, args, env=None, check=True):
        result = subprocess.run([str(a) for a in args], cwd=ROOT, env=dict(self.env, **(env or {})),
                                capture_output=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
        return result

    def state(self, expression, repo='fixture/repo'):
        return json.loads(self.invoke([self.session, '--repo', repo, '--get-json', expression]).stdout)

    def handoff_state(self):
        return json.loads(self.invoke([self.handoff, '--owner-repo', 'fixture/repo', '--get', '7']).stdout)

    def gate(self, raw, code, env=None):
        self.out.write_bytes(raw)
        values = dict(FIXTURE_EXIT=str(code), GATE_JSON='{"met":true,"missing":[],"head_sha":"stale"}')
        values.update(env or {})
        return self.invoke(['bash', '-eu', '-c', self.wrap_capture+'\n'+self.wrap_save], values, check=False)

    def test_real_gate_capture_classification_and_raw_recovery(self):
        passed = dict(met=True, missing=[], head_sha='a'*40, additional={'complete': 'retained'})
        blocked = dict(met=False, missing=['human CHANGES_REQUESTED', 'CI failing'], head_sha='a'*40)
        cases = [(b'', 2, 'execution_error'), (b'not JSON', 4, 'execution_error'),
                 (b'', 0, 'empty_output'), (b'bad', 0, 'malformed_output'),
                 (b'{}{}', 0, 'malformed_output'),
                 (b'['*2000+b']'*2000, 0, ('malformed_output', 'invalid_shape')),
                 (b'[]', 0, 'invalid_shape'),
                 (b'{"met":"true"}', 0, 'invalid_shape'), (b'\xff', 0, 'invalid_encoding'),
                 (json.dumps(blocked).encode(), 0, 'exit_verdict_mismatch'),
                 (json.dumps(passed).encode(), 1, 'exit_verdict_mismatch'),
                 (json.dumps(dict(passed, missing=['hard stop'])).encode(), 0, 'exit_verdict_mismatch'),
                 (json.dumps(blocked).encode(), 1, 'valid_blocked'),
                 (json.dumps(passed).encode(), 0, 'valid_pass')]
        for raw, code, expected in cases:
            with self.subTest(code=code, expected=expected):
                result = self.gate(raw, code)
                self.assertEqual(result.returncode == 0, expected in ('valid_pass', 'valid_blocked'))
                record = self.state('.prs["7"].wrap_sweep.recovery_audit')
                allowed = expected if isinstance(expected, tuple) else (expected,)
                self.assertIn(record['classification'], allowed)
                self.assertEqual(record['exit_code'], code)
                self.assertEqual(Path(record['raw_stdout_path']).read_bytes(), raw)
                self.assertEqual(Path(record['raw_stderr_path']).read_bytes(), self.err.read_bytes())
                self.assertEqual(record['cycles'], self.env['WRAP_RECOVERY_AUDIT'])
                self.assertEqual(result.stdout, b'')
                projection = self.invoke([self.helper, 'show', '--kind', 'gate', '--repo', 'fixture/repo',
                                          '--pr', '7', '--directory', record['capture_dir']])
                self.assertEqual(json.loads(projection.stdout)['classification'], record['classification'])
                recovered = self.invoke([self.helper, 'show', '--kind', 'gate', '--repo', 'fixture/repo',
                                         '--pr', '7', '--directory', record['capture_dir'], '--raw', 'stdout'])
                self.assertEqual(recovered.stdout, raw)
        self.assertEqual(record['last_gate'], passed)
        self.assertIsNone(self.state('.prs["7"].wrap_sweep.recovery_audit', 'wrong/repo'))
        self.assertGreater(len(self.state('.prs["7"].wrap_sweep.recovery_failures')), 0)

    def test_failed_gate_storage_keeps_previous_record_and_scope(self):
        raw = json.dumps(dict(met=False, missing=['CI failed'], head_sha='a'*40)).encode()
        self.assertEqual(self.gate(raw, 1).returncode, 0)
        before = self.state('.prs["7"].wrap_sweep')
        result = self.gate(b'broken', 4, {'WRAP_AUDIT_STATE_SH': '/usr/bin/false'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state('.prs["7"].wrap_sweep'), before)
        self.assertIn(b'raw capture:', result.stderr)
        foreign = self.invoke([self.helper, 'new', '--kind', 'gate', '--repo', 'other/repo', '--pr', '7']).stdout.decode().strip()
        prior_audit = (Path(foreign)/'audit').read_bytes()
        result = self.invoke(['bash', '-eu', '-c', self.wrap_save],
                             {'WRAP_GATE_CAPTURE': foreign, 'GATE_RC': '4'}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((Path(foreign)/'audit').read_bytes(), prior_audit)
        self.assertEqual(self.state('.prs["7"].wrap_sweep'), before)

    def wait(self, verdict, bundle, code=0, env=None):
        values = dict(WAIT_STATE=verdict, TICK=str(bundle), WAIT_EVAL_RC=str(code))
        values.update(env or {})
        return self.invoke(['bash', '-eu', '-c', self.wait_functions+'\npersist_fixpr_wait_evidence'], values, check=False)

    @staticmethod
    def verdict(failed=False):
        return json.dumps(dict(bots_pending=[], ci_pending=[], ci_failing=[{'name': 'build'}] if failed else [],
                               new_findings=0, head_moved=False))

    def test_wait_failures_survive_distinct_later_clean_snapshot_and_original_expiry(self):
        failed_bundle = self.home/'failed-bundle.json'
        failed_bundle.write_bytes(b'{"raw_failure":"full original capture"}\n')
        result = self.wait(self.verdict(True), failed_bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.handoff_state()
        self.assertEqual(len(first['fixpr_wait_failures']), 1)
        failing = next(iter(first['fixpr_wait_failures'].values()))
        failed_bundle.unlink()
        clean_bundle = self.home/'clean-bundle.json'
        clean_bundle.write_text('{"clean":true}')
        result = self.wait(self.verdict(), clean_bundle)
        self.assertEqual(result.returncode, 0, result.stderr)
        current = self.handoff_state()
        self.assertEqual(current['fixpr_wait']['bundle_path'], str(clean_bundle))
        self.assertEqual(current['fixpr_wait']['classification'], 'valid_clean')
        self.assertEqual(current['fixpr_wait_failures'], first['fixpr_wait_failures'])
        raw = self.invoke([self.helper, 'show', '--kind', 'wait', '--repo', 'fixture/repo', '--pr', '7',
                           '--directory', failing['capture_dir'], '--raw', 'bundle'])
        self.assertEqual(raw.stdout, b'{"raw_failure":"full original capture"}\n')

    def test_wait_empty_malformed_error_and_missing_bundle_are_indexed_before_stop(self):
        bundle = self.home/'bundle'
        bundle.write_bytes(b'\xff raw bundle retained byte-for-byte')
        for value, code, expected in [('', 0, 'empty_output'), ('bad', 0, 'malformed_output'),
                                      ('[]', 0, 'invalid_shape'), (self.verdict(), 3, 'execution_error')]:
            result = self.wait(value, bundle, code)
            self.assertNotEqual(result.returncode, 0)
            record = self.handoff_state()['fixpr_wait']
            self.assertEqual(record['classification'], expected)
            self.assertEqual(Path(record['raw_stdout_path']).read_text(), value)
            self.assertEqual(Path(record['retained_bundle_path']).read_bytes(), bundle.read_bytes())
        bundle.unlink()
        self.assertNotEqual(self.wait(self.verdict(), bundle).returncode, 0)
        record = self.handoff_state()['fixpr_wait']
        self.assertEqual(record['classification'], 'bundle_unavailable')
        self.assertEqual(record['bundle_path'], str(bundle))

    def test_actual_wait_fetch_evaluator_failure_and_failed_storage(self):
        bundle = self.home/'bundle'
        bundle.write_text('{"retained":"original bundle"}')
        fetcher = self.home/'fetcher'
        fetcher.write_text('''#!/bin/sh
if [ "$1" = --pr ]; then
 printf '%s\\n' "$FIXTURE_BUNDLE"; printf fetch-diagnostic >&2; exit "$FIXTURE_FETCH_EXIT"
fi
printf '%s' "$FIXTURE_EVAL_OUTPUT"; printf evaluator-diagnostic >&2; exit "$FIXTURE_EVAL_EXIT"
''')
        fetcher.chmod(0o755)
        values = dict(SCRIPT=str(fetcher), FIXTURE_BUNDLE=str(bundle), FIXTURE_FETCH_EXIT='0',
                      FIXTURE_EVAL_OUTPUT='', FIXTURE_EVAL_EXIT='4')
        result = self.invoke(['bash', '-eu', '-c', self.wait_functions+'\ncapture_fixpr_wait_evidence'], values, check=False)
        self.assertNotEqual(result.returncode, 0)
        record = self.handoff_state()['fixpr_wait']
        self.assertEqual(record['exit_code'], 4)
        self.assertEqual(Path(record['fetch_stderr_path']).read_text(), 'fetch-diagnostic')
        self.assertEqual(Path(record['raw_stderr_path']).read_text(), 'evaluator-diagnostic')
        values['FIXTURE_FETCH_EXIT'] = '2'
        result = self.invoke(['bash', '-eu', '-c', self.wait_functions+'\ncapture_fixpr_wait_evidence'], values, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.handoff_state()['fixpr_wait']['fetch_exit_code'], 2)
        before = self.handoff_state()
        result = self.wait(self.verdict(), bundle, env={'HANDOFF_STATE_SH': '/usr/bin/false'})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.handoff_state(), before)

    def test_private_permissions_and_invalid_scope(self):
        self.gate(b'', 4)
        record = self.state('.prs["7"].wrap_sweep.recovery_audit')
        directory = Path(record['capture_dir'])
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o600 for p in directory.iterdir()))
        bad = self.invoke([self.helper, 'new', '--kind', 'gate', '--repo', '../..', '--pr', '7'], check=False)
        self.assertNotEqual(bad.returncode, 0)

    def test_partial_wait_write_retains_previous_latest_and_new_failure(self):
        bundle = self.home/'bundle'
        bundle.write_text('{"fixture":true}')
        self.assertEqual(self.wait(self.verdict(), bundle).returncode, 0)
        before = self.handoff_state()['fixpr_wait']
        writer = self.home/'history-only-writer'
        writer.write_text('''#!/bin/sh
for arg do
 case "$arg" in .fixpr_wait=*) exit 5;; esac
done
exec "$REAL_HANDOFF" "$@"
''')
        writer.chmod(0o755)
        result = self.wait(self.verdict(True), bundle,
                           env={'HANDOFF_STATE_SH': str(writer), 'REAL_HANDOFF': str(self.handoff)})
        self.assertNotEqual(result.returncode, 0)
        current = self.handoff_state()
        self.assertEqual(current['fixpr_wait'], before)
        self.assertEqual(len(current['fixpr_wait_failures']), 1)

    def test_concurrent_failures_keep_both_locked_history_keys(self):
        bundle = self.home/'bundle'
        bundle.write_text('{"fixture":true}')
        values = dict(self.env, WAIT_STATE=self.verdict(True), TICK=str(bundle))
        children = [subprocess.Popen(['bash', '-eu', '-c', self.wait_functions+'\npersist_fixpr_wait_evidence'],
                                     cwd=ROOT, env=values, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    for _ in range(2)]
        for child in children:
            stdout, stderr = child.communicate(timeout=30)
            self.assertEqual(child.returncode, 0, stderr)
            self.assertEqual(stdout, b'')
        self.assertEqual(len(self.handoff_state()['fixpr_wait_failures']), 2)

    def test_oversized_output_retains_full_raw_file_and_blocks_parsing(self):
        original = b'x' * (8*1024*1024+10)
        self.assertNotEqual(self.gate(original, 0).returncode, 0)
        record = self.state('.prs["7"].wrap_sweep.recovery_audit')
        self.assertEqual(record['classification'], 'output_parse_limit')
        self.assertEqual(Path(record['raw_stdout_path']).read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
