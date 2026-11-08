"""Exercise selected legacy waits through the production loader and locked helpers."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / '.claude/scripts'


class WaitHandoffSelectionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='wait-handoff-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.temp = Path(self.temporary.name)
        self.home, self.repo, self.bin = self.temp/'home', self.temp/'repo', self.temp/'bin'
        self.home.mkdir()
        self.sha = 'a'*40
        self.env = dict(os.environ, HOME=str(self.home), CLAUDE_SESSION_REPO='wrong/repo',
                        STUB_OWNER_REPO='fixture/repo', STUB_PR_NUMBER='7', STUB_HEAD_SHA=self.sha,
                        PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        OWNER_REPO='fixture/repo', PR_NUMBER='7', WATCH_SHA=self.sha,
                        WAIT_BASELINE='2026-11-07T23:00:00Z', WAIT_FETCH_RC='0', WAIT_EVAL_RC='0',
                        HANDOFF_STATE_SH=str(SCRIPTS/'handoff-state.sh'),
                        RECOVERY_EVIDENCE_SH=str(SCRIPTS/'recovery-evidence.sh'),
                        POLLING_STATE_GATE_SH=str(SCRIPTS/'polling-state-gate.sh'))
        for key in ('CLAUDE_SESSION_STATE_FILE','CLAUDE_HANDOFF_ROOT','WAIT_CAPTURE_DIR'):
            self.env.pop(key,None)
        self.call(['bash','-eu','-c','source "$1"; mk_repo "$2" https://github.com/fixture/repo.git; write_polling_gh_stub "$3"',
                   'fixture',SCRIPTS/'tests/lib/polling-state-gate-fixtures.sh',self.repo,self.bin],cwd=ROOT)
        self.record = dict(pr_number=7, owner_repo='fixture/repo', head_sha=self.sha,
                           notes='preserve complete handoff', files_changed=['preserve-me'],
                           custom={'unknown_fields':['keep','all']})
        self.flat = self.home/'.claude/handoffs/pr-7-handoff.json'
        self.scoped = self.home/'.claude/handoffs/fixture/repo/pr-7-handoff.json'
        self.bundle = self.temp/'bundle.json'
        self.bundle.write_bytes(b'{"full":"raw bundle bytes retained"}\n')
        self.env.update(TICK=str(self.bundle),WAIT_STATE=json.dumps(dict(head_moved=False,
                        bots_pending=[],ci_pending=[],ci_failing=[],new_findings=0)))
        text=(ROOT/'.claude/skills/fixpr/SKILL.md').read_text()
        self.loader=text.split('<!-- test-anchor: fixpr-persist-wait-evidence -->',1)[1].split('```bash\n',1)[1].split('\n```',1)[0]

    def call(self,args,check=True,cwd=None,extra=None):
        result=subprocess.run([str(a) for a in args],cwd=cwd or self.repo,
                              env=dict(self.env,**(extra or {})),capture_output=True,timeout=45)
        if check:
            self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        return result

    def initialize(self,legacy=True):
        flags=['--legacy-flat'] if legacy else ['--owner-repo','fixture/repo']
        self.call([SCRIPTS/'handoff-state.sh',*flags,'--create','7',json.dumps(self.record)])
        self.call([SCRIPTS/'polling-state-gate.sh','7','--ensure-session','--repo','fixture/repo','--root-repo',self.repo])
        # Every subsequent selection must be offline, even inside the loader.
        self.unexpected=self.temp/'unexpected-gh'
        (self.bin/'gh').write_text('#!/bin/sh\nprintf unexpected > "$UNEXPECTED_GH"\nexit 99\n')
        self.env['UNEXPECTED_GH']=str(self.unexpected)

    def persist(self,check=False,extra=None,tail=''):
        return self.call(['bash','-eu','-c',self.loader+'\npersist_fixpr_wait_evidence\n'+tail],check=check,extra=extra)

    def assert_preserved(self,path):
        result=json.loads(path.read_text())
        for key,value in self.record.items():
            self.assertEqual(result[key],value)
        return result

    def test_selected_legacy_keeps_full_record_and_raw_bundle(self):
        self.initialize()
        selected=json.loads(self.call([SCRIPTS/'polling-state-gate.sh','7','--resolve-handoff','--repo','fixture/repo','--root-repo',self.repo]).stdout)
        self.assertEqual(selected['scope'],'legacy-flat')
        self.assertEqual(selected['path'],str(self.flat))
        result=self.persist(check=True)
        self.assertEqual(result.stdout,b'')
        data=self.assert_preserved(self.flat)
        wait=data['fixpr_wait']
        self.assertEqual(wait['head_sha'],self.sha)
        self.assertEqual(wait['baseline'],self.env['WAIT_BASELINE'])
        self.assertEqual(Path(wait['retained_bundle_path']).read_bytes(),self.bundle.read_bytes())
        self.assertFalse(self.scoped.exists())
        self.assertFalse(self.unexpected.exists())

    def test_fresh_scoped_behavior_and_explicit_scope(self):
        self.initialize(legacy=False)
        selected=json.loads(self.call([SCRIPTS/'polling-state-gate.sh','7','--resolve-handoff',
                            '--repo','fixture/repo','--root-repo',self.repo]).stdout)
        self.assertEqual(selected['scope'],'scoped')
        self.assertEqual(selected['path'],str(self.scoped))
        self.persist(check=True)
        data=self.assert_preserved(self.scoped)
        self.assertEqual(data['fixpr_wait']['verdict']['new_findings'],0)
        self.assertFalse(self.flat.exists())
        self.assertFalse(self.unexpected.exists())

    def test_unattributed_foreign_wrong_pr_and_changed_head_refuse(self):
        self.initialize()
        for change in ({'owner_repo':None},{'owner_repo':'foreign/repo'},
                       {'pr_number':8},{'head_sha':'b'*40}):
            with self.subTest(change=change):
                value=dict(self.record,**change);self.flat.write_text(json.dumps(value))
                before=self.flat.read_bytes();result=self.persist()
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(self.flat.read_bytes(),before)
                self.assertFalse(self.scoped.exists())
                self.assertIn(b'ERROR',result.stderr)
        self.assertFalse(self.unexpected.exists())

    def test_missing_malformed_and_nonobject_are_not_clean(self):
        self.initialize()
        for raw in (None,b'{bad',b'[]',b'{}{}'):
            with self.subTest(raw=raw):
                if raw is None:self.flat.unlink(missing_ok=True)
                else:self.flat.write_bytes(raw)
                result=self.persist()
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(self.scoped.exists())
                if raw is not None:self.assertEqual(self.flat.read_bytes(),raw)
        self.assertTrue(list((self.home/'.claude/logs/recovery-evidence').rglob('stdout')))

    def shim(self,action):
        path=self.temp/'handoff-shim'
        path.write_text('''#!/bin/bash
set -eu
for arg in "$@"; do
  if [[ "$arg" == --set && ! -f "$SHIM_ONCE" ]]; then
    : > "$SHIM_ONCE"
'''+action+'''
    break
  fi
done
exec "$REAL_HANDOFF" "$@"
''')
        path.chmod(0o755)
        self.env.update(HANDOFF_STATE_SH=str(path),REAL_HANDOFF=str(SCRIPTS/'handoff-state.sh'),
                        SHIM_ONCE=str(self.temp/'once'),FLAT=str(self.flat),SCOPED=str(self.scoped))

    def test_locked_identity_guard_rejects_replacement_after_selection(self):
        self.initialize()
        self.shim('"$REAL_HANDOFF" --legacy-flat --set 7 \'.owner_repo="foreign/repo"\'')
        result=self.persist()
        self.assertNotEqual(result.returncode,0)
        data=json.loads(self.flat.read_text())
        self.assertEqual(data['owner_repo'],'foreign/repo')
        self.assertNotIn('fixpr_wait',data)
        self.assertIn(b'identity changed',result.stderr)
        self.assertFalse(self.scoped.exists())

    def test_migration_after_selection_never_creates_legacy_shadow(self):
        self.initialize()
        self.shim('mkdir -p "${SCOPED%/*}"\nmv "$FLAT" "$SCOPED"')
        result=self.persist()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads(self.scoped.read_text()),self.record)
        self.assertFalse(self.flat.exists())

    def test_scoped_appearance_blocks_guarded_legacy_write(self):
        self.initialize()
        self.shim('mkdir -p "${SCOPED%/*}"\ncp "$FLAT" "$SCOPED"')
        result=self.persist()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads(self.flat.read_text()),self.record)
        self.assertEqual(json.loads(self.scoped.read_text()),self.record)
        self.assertIn(b'lane changed',result.stderr)

    def test_failed_write_preserves_record_and_private_capture(self):
        self.initialize()
        self.shim('exit 5')
        before=self.flat.read_bytes();result=self.persist()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.flat.read_bytes(),before)
        self.assertFalse(self.scoped.exists())
        captures=list((self.home/'.claude/logs/recovery-evidence').rglob('record.json'))
        self.assertTrue(captures,'raw failure record must remain recoverable without a handoff index')


if __name__=='__main__':
    unittest.main()
