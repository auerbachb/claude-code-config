#!/usr/bin/env bash
# catalog: tests — Tests real per-session round dispatch/teardown, observer/legacy reads and board queue derivation
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ROUND_TEST_SHELL="${ROUND_TEST_SHELL:-$BASH}" python3 - "$ROOT" "$@" <<'PY'
import copy,json,os,re,shlex,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(sys.argv[1]);SHELL=os.environ['ROUND_TEST_SHELL'];REPO='auerbachb/claude-code-config';STAMP='2026-09-02T18:38:00Z'
SUBAGENT=Path(os.environ.get('ROUND_TEST_SUBAGENT_SOURCE',ROOT/'.claude/skills/subagent/SKILL.md')).read_text();BOARD=(ROOT/'.claude/skills/board/SKILL.md').read_text()
def fence(source,name):
    # Use the shipped extractor: list-indented closing fences are Markdown too.
    with tempfile.NamedTemporaryFile('w',suffix='.md') as document:
        document.write(source);document.flush()
        return subprocess.check_output([SHELL,'-c','source "$1"; extract_skill_bash "$2" "$3"','--',str(ROOT/'.claude/scripts/tests/lib/skill-bash.sh'),document.name,name],text=True).rstrip('\n')
WRITE=fence(SUBAGENT,'subagent-step7-round-membership-write');CLEAR=fence(SUBAGENT,'subagent-step8-round-teardown-clear');QUEUE=fence(BOARD,'board-step3-queued-from-round')
def issues(block,name,values):
    pattern=r'(?m)^(\s*)'+name+r'=\(<[^\n]*\)$';out,n=re.subn(pattern,lambda m:m.group(1)+name+'=('+ ' '.join(shlex.quote(v) for v in values)+')',block)
    if n!=1:raise AssertionError('caller issue placeholder was not bound')
    return out
def record(session,members,**extra):return dict(members=members,dispatched_at=STAMP,session=session,**extra)
class Rounds(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='rounds-native-');self.addCleanup(self.tmp.cleanup);self.home=Path(self.tmp.name);(self.home/'.claude').mkdir();self.state=self.home/'.claude/session-state.json';self.data={'repos':{REPO:{'pipelines':{}},'foreign/repo':{'sentinel':False}}};self.save(self.data)
        self.real=ROOT/'.claude/scripts/session-state.sh';self.helper=self.home/'state-wrapper.sh';self.helper.write_text('''#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [[ "$arg" == --repo-key && "${UNRESOLVED:-false}" == true ]]; then echo _unknown; exit 0; fi
  if [[ "$arg" == --get-json && "${READ_FAIL:-false}" == true ]]; then exit 6; fi
  if [[ "$arg" == --cas ]]; then
    printf 'cas\\n' >> "$TEST_CALLS"
    if [[ -n "${RACE_VALUE:-}" ]] && mkdir "$RACE_ONCE" 2>/dev/null; then
      "$REAL_STATE" --repo "$TEST_REPO" --set "$RACE_PATH=$(cat "$RACE_VALUE")" || exit 1
    fi
  fi
done
exec "$REAL_STATE" "$@"
''');self.helper.chmod(0o700)
        self.env=os.environ.copy();self.env.update(HOME=str(self.home),SESSION_STATE_SH=str(self.helper),REAL_STATE=str(self.real),TEST_REPO=REPO,REPO_KEY=REPO,TEST_CALLS=str(self.home/'calls'),RACE_ONCE=str(self.home/'once'))
    def save(self,data):self.state.write_text(json.dumps(data))
    def load(self):return json.loads(self.state.read_text())
    def repo(self):return self.load()['repos'][REPO]
    def run_block(self,block,session='sess-a',extra=None):
        env=self.env.copy();env.pop('CLAUDE_SESSION_ID',None)
        if session is not None:env['CLAUDE_SESSION_ID']=session
        env.update(extra or {});return subprocess.run([SHELL,'-u','-c',block],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
    def write(self,session,members,extra=None):return self.run_block(issues(WRITE,'ROUND_ISSUES',members),session,extra)
    def clear(self,session,members,extra=None):return self.run_block(issues(CLEAR,'ENDED_ROUND_ISSUES',members),session,extra)
    def read(self,session='',repo=REPO,extra=None):
        env=self.env.copy();env.update(extra or {});return subprocess.run([SHELL,str(ROOT/'.claude/scripts/round-membership.sh'),'--repo',repo,'--session',session,'--state-helper',str(self.helper)],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
    def members(self,session='',repo=REPO):
        p=self.read(session,repo);self.assertEqual(p.returncode,0,p.stderr);return json.loads(p.stdout)
    def seed(self,rounds=None,legacy=None):
        data=copy.deepcopy(self.data)
        if rounds is not None:data['repos'][REPO]['rounds']=rounds
        if legacy is not None:data['repos'][REPO]['round']=legacy
        self.save(data)
    def race(self,session,value):
        p=self.home/'race.json';p.write_text(json.dumps(value));return dict(RACE_VALUE=str(p),RACE_PATH=f'.repos["{REPO}"].rounds["{session}"]')
    def assert_cas_once(self):self.assertEqual((self.home/'calls').read_text().splitlines(),['cas'])
    def test_two_active_dispatchers_keep_their_own_membership(self):
        for session,members in [('sess-a',['1','2']),('sess-b',['3','4'])]:
            p=self.write(session,members);self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(self.members('sess-a')['members'],['1','2'],'dispatcher B replaced A membership');self.assertEqual(self.members('sess-b')['members'],['3','4']);self.assertEqual(self.members('observer')['members'],['1','2','3','4']);self.assertEqual(self.load()['repos']['foreign/repo'],{'sentinel':False})
    def test_equal_members_of_two_sessions_are_distinct_rounds(self):
        self.seed({'sess-a':record('sess-a',['1','2'])});p=self.write('sess-b',['1','2']);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.repo()['rounds']['sess-a']['dispatched_at'],STAMP);self.assertEqual(self.repo()['rounds']['sess-b']['session'],'sess-b');self.assertNotEqual(self.repo()['rounds']['sess-b']['dispatched_at'],STAMP)
    def test_same_set_reentry_performs_no_write(self):
        self.seed({'sess-a':record('sess-a',['1','2'],unknown=False)});before=self.state.read_bytes();p=self.write('sess-a',['1','2']);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.state.read_bytes(),before);self.assertFalse((self.home/'calls').exists())
    def test_reorder_preserves_original_time_and_unknown_metadata(self):
        self.seed({'sess-a':record('sess-a',['1','2'],unknown=False)});p=self.write('sess-a',['2','1']);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.repo()['rounds']['sess-a'],record('sess-a',['2','1'],unknown=False));self.assert_cas_once()
    def test_changed_set_replaces_only_own_round_without_merging(self):
        for old,new in [(['1','2'],['1']),(['1'],['1','2']),(['1','2'],['3'])]:
            with self.subTest(old=old,new=new):
                other=record('sess-b',['99'],unknown={'keep':False});self.seed({'sess-a':record('sess-a',old,old_only=True),'sess-b':other});p=self.write('sess-a',new);self.assertEqual(p.returncode,0,p.stderr);v=self.repo()['rounds'];self.assertEqual(v['sess-a']['members'],new);self.assertNotIn('old_only',v['sess-a']);self.assertEqual(v['sess-b'],other)
    def test_same_session_cas_loss_is_retained_without_retry(self):
        winner=record('sess-a',['999'],winner=True);p=self.write('sess-a',['1'],self.race('sess-a',winner));self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.repo()['rounds']['sess-a'],winner);self.assertIn('changed',p.stdout);self.assert_cas_once()
    def test_different_session_publication_does_not_lose_own_slot(self):
        other=record('sess-b',['99']);p=self.write('sess-a',['1','2'],self.race('sess-b',other));self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.repo()['rounds']['sess-b'],other);self.assertEqual(self.members('sess-a')['members'],['1','2'])
    def test_clear_owns_one_slot_and_retains_legacy_and_sibling(self):
        other=record('sess-b',['3']);legacy=record('sess-a',['90']);self.seed({'sess-a':record('sess-a',['1','2']),'sess-b':other},legacy);p=self.clear('sess-a',['2','1']);self.assertEqual(p.returncode,0,p.stderr);self.assertIsNone(self.repo()['rounds']['sess-a']);self.assertEqual(self.repo()['rounds']['sess-b'],other);self.assertEqual(self.repo()['round'],legacy);self.assertEqual(self.members('observer')['members'],['3'])
    def test_stale_clear_cannot_remove_a_new_same_session_round(self):
        self.seed({'sess-a':record('sess-a',['99'])});before=self.state.read_bytes();p=self.clear('sess-a',['1']);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.state.read_bytes(),before)
    def test_clear_cas_loss_retains_the_replacement(self):
        self.seed({'sess-a':record('sess-a',['1'])});winner=record('sess-a',['99']);p=self.clear('sess-a',['1'],self.race('sess-a',winner));self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.repo()['rounds']['sess-a'],winner);self.assert_cas_once()
    def test_foreign_same_members_are_never_cleared(self):
        self.seed({'sess-b':record('sess-b',['1'])});before=self.state.read_bytes();p=self.clear('sess-a',['1']);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.state.read_bytes(),before)
    def test_unknown_identity_repo_or_empty_issue_list_degrades_without_writing(self):
        for session,members,extra in [(None,['1'],{}),('default',['1'],{}),('bad"key',['1'],{}),('sess-a',[],{}),('sess-a',['0'],{}),('sess-a',['1'],{'UNRESOLVED':'true'})]:
            with self.subTest(session=session,members=members,extra=extra):
                self.save(self.data);before=self.state.read_bytes();p=self.write(session,members,extra);self.assertEqual(p.returncode,0,p.stderr);self.assertIn('DEGRADED',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_missing_ended_list_or_identity_never_clears(self):
        for session,members in [('sess-a',[]),(None,['1']),('default',['1'])]:
            with self.subTest(session=session,members=members):
                self.seed({'sess-a':record('sess-a',['1'])});before=self.state.read_bytes();p=self.clear(session,members);self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(self.state.read_bytes(),before);self.assertIn('DEGRADED',p.stdout)
    def test_read_failure_or_malformed_own_slot_is_retained(self):
        for value,extra in [(record('sess-a',['1']),{'READ_FAIL':'true'}),(False,{}),(['bad'],{}),(record('sess-b',['1']),{}),(dict(record('sess-a',['1']),dispatched_at='not-a-time'),{})]:
            with self.subTest(value=value,extra=extra):
                self.seed({'sess-a':value});before=self.state.read_bytes();p=self.write('sess-a',['2'],extra);self.assertEqual(p.returncode,0,p.stderr);self.assertIn('DEGRADED',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_clear_read_failure_is_not_a_successful_clear(self):
        self.seed({'sess-a':record('sess-a',['1'])});before=self.state.read_bytes();p=self.clear('sess-a',['1'],{'READ_FAIL':'true'});self.assertEqual(p.returncode,0,p.stderr);self.assertIn('unreadable',p.stdout);self.assertEqual(self.state.read_bytes(),before)
    def test_observer_order_dedup_and_legacy_attribution(self):
        self.seed({'sess-b':record('sess-b',['2','3']),'sess-a':record('sess-a',['1','2'])},record('legacy',['4','1']));before=self.state.read_bytes();self.assertEqual(self.members('observer'),dict(members=['1','2','3','4'],scope='observer'));self.assertEqual(self.members('sess-b'),dict(members=['2','3'],scope='own'));self.assertEqual(self.state.read_bytes(),before)
    def test_tombstone_shadows_attributed_legacy_without_deleting_it(self):
        legacy=record('sess-a',['9']);self.seed({'sess-a':None},legacy);before=self.state.read_bytes();self.assertEqual(self.members('sess-a'),dict(members=None,scope='none'));self.assertEqual(self.state.read_bytes(),before)
    def test_unattributed_legacy_remains_visible(self):
        legacy=record('unused',['8']);del legacy['session'];self.seed({'sess-a':record('sess-a',['1'])},legacy);self.assertEqual(self.members('observer')['members'],['1','8']);self.seed(legacy=legacy);self.assertEqual(self.members('observer'),dict(members=['8'],scope='legacy'))
    def test_absent_state_is_known_none_and_reader_creates_no_state(self):
        self.state.unlink();p=self.read();self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(json.loads(p.stdout),dict(members=None,scope='none'));self.assertFalse(self.state.exists())
    def test_malformed_reader_state_fails_closed_without_fake_membership(self):
        values=[{'rounds':False},{'round':False},{'rounds':[]},{'rounds':{'sess-a':record('sess-b',['1'])}},{'rounds':{'sess-a':dict(record('sess-a',['1']),members=[False])}},{'round':dict(record('old',['1']),dispatched_at='2026-02-31T00:00:00Z')}]
        for value in values:
            with self.subTest(value=value):
                data=copy.deepcopy(self.data);data['repos'][REPO].update(value);self.save(data);before=self.state.read_bytes();p=self.read('sess-a');self.assertEqual(p.returncode,5,p.stderr);self.assertEqual(p.stdout,'');self.assertEqual(self.state.read_bytes(),before)
    def test_reader_io_failure_has_no_success_json(self):
        before=self.state.read_bytes();p=self.read(extra={'READ_FAIL':'true'});self.assertEqual(p.returncode,5,p.stderr);self.assertEqual(p.stdout,'');self.assertEqual(self.state.read_bytes(),before)
    def test_reader_repo_scope_does_not_adopt_current_checkout(self):
        data=copy.deepcopy(self.data);data['repos'][REPO]['rounds']={'sess-a':record('sess-a',['1'])};data['repos']['other/repo']={'rounds':{'sess-a':record('sess-a',['99'])}};self.save(data);self.assertEqual(self.members('sess-a','other/repo')['members'],['99']);self.assertEqual(self.members('sess-a')['members'],['1'])
    def test_actual_board_queue_derivation_preserves_all_old_cases(self):
        cases=[(['1','2','3'],{'1':{'started_at':STAMP}},'2\n3'),(['1','2','3'],{'1':{'started_at':'A'},'2':{'started_at':'B'}},'3'),(['1'],{'1':{'started_at':'A'}},''),(['1','2'],None,'1\n2'),(['1'],{'1':{'pr':10}},'1')]
        for members,pipelines,want in cases:
            with self.subTest(members=members,pipelines=pipelines):
                p=self.run_block(QUEUE+'\nprintf "%s" "$QUEUED_ISSUES"',extra=dict(ROW_ROUND_MEMBERS=json.dumps(members),ROW_PIPELINES='' if pipelines is None else json.dumps(pipelines)));self.assertEqual(p.returncode,0,p.stderr);self.assertEqual(p.stdout,want)
    def test_native_schema_and_board_wiring_preserve_scope_and_evidence(self):
        schema=json.loads((ROOT/'.claude/reference/session-state-schema.json').read_text());sample=next(iter(schema['repos'].values()));self.assertIn('rounds',sample);self.assertIn('_rounds_comment',sample)
        for phrase in ['Step 7.0','Step 8','/board','--session-view']:self.assertIn(phrase,sample['_rounds_comment'])
        self.assertNotIn('rounds',json.dumps(schema.get('_field_types',{})));self.assertIn('read_round_membership "$EFFECTIVE_REPO"',BOARD);self.assertIn('read_round_membership "$RK"',BOARD);self.assertIn('ROUND_MEMBERSHIP_SH=$(resolve_script round-membership.sh',BOARD);self.assertIn('Recorded rounds (observer view)',' '.join(BOARD.split()));self.assertIn('liveness unconfirmed',' '.join(BOARD.split()));self.assertIn('A recorded queue does not, by itself, open a round',BOARD);self.assertIn('Only when that repo has no round record',BOARD);self.assertIn('TF_SESSION="${CLAUDE_SESSION_ID:-default}"',BOARD)
        self.assertLess(SUBAGENT.index('subagent-step7-round-membership-write'),SUBAGENT.index('### 7.1:'))
        self.assertIn("Only the round's END clears it",SUBAGENT);wave=(ROOT/'.claude/skills/wave/SKILL.md').read_text();self.assertIn('/wave` writes no round-membership record',wave);self.assertNotRegex(wave,r'--(?:set|cas) [^\n]*\.round(?:s|\.)?=')
if __name__=='__main__':unittest.main(argv=[sys.argv[0],*sys.argv[2:]],verbosity=2)
PY
