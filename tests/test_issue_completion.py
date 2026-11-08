"""Exercise the real completion CLI against an isolated, stateful GitHub fixture."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HELPER = Path(__file__).parents[1] / '.claude/scripts/lib/issue_completion.py'
MERGE = 'a' * 40
FAKE_GH = r'''#!/usr/bin/env python3
import json,os,signal,sys
from pathlib import Path
root=Path(os.environ['COMPLETION_FIXTURE']); args=sys.argv[1:]
with (root/'calls').open('a') as f:f.write(json.dumps(args)+'\n')
mode=(root/'mode').read_text(); state=json.loads((root/'state').read_text())
if mode=='api-error':sys.exit(1)
if mode=='invalid-json':print('{');sys.exit(0)
if '--method' in args:
 if mode=='write-error':sys.exit(1)
 state['state']='CLOSED';state['writes']+=1;(root/'state').write_text(json.dumps(state))
 if mode=='interrupted':os.kill(os.getppid(),signal.SIGKILL)
 print(json.dumps({'state':'closed'}));sys.exit(0)
query=next(a[6:] for a in args if a.startswith('query='))
if 'pullRequest(number:' in query:
 d=json.loads((root/'pr').read_text())
 if d['data'].get('repository') is None:print(json.dumps(d));sys.exit(0)
 for node in d['data']['repository']['pullRequest']['closingIssuesReferences']['nodes']:
  if node['number']==7 and node['repository']['nameWithOwner']=='owner/consumer':node['state']=state['state']
 print(json.dumps(d))
else:
 number=int(next(a[7:] for a in args if a.startswith('number=')))
 print(json.dumps({'data':{'repository':{'nameWithOwner':'owner/consumer','issueOrPullRequest':dict(__typename='PullRequest' if mode=='wrong-type' else 'Issue',number=number,state='OPEN' if mode=='delayed' else state['state'],closedAt=None,url='https://github.com/owner/consumer/issues/'+str(number),repository={'nameWithOwner':'owner/consumer'},timelineItems={'nodes':[{'createdAt':'2026-11-05T00:00:00Z'}] if mode=='reopened' else []})}}}))
'''


class Completion(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='issue-1973-completion-')
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root/'home'; self.home.mkdir(mode=0o700)
        binary = self.root/'bin'; binary.mkdir()
        stub = binary/'gh'; stub.write_text(FAKE_GH); stub.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), COMPLETION_FIXTURE=str(self.root), PATH=str(binary)+os.pathsep+os.environ['PATH'])
        self.mode('normal')
        self.state = dict(state='OPEN', writes=0)
        self.write_state()
        self.pr = dict(data=dict(viewer=dict(login='owner'),repository=dict(nameWithOwner='owner/consumer',defaultBranchRef=dict(name='main'),pullRequest=dict(number=20,state='MERGED',mergedAt='2026-11-04T21:22:58Z',headRefOid='b'*40,baseRefName='main',url='https://github.com/owner/consumer/pull/20',author=dict(login='owner'),mergeCommit=dict(oid=MERGE),closingIssuesReferences=dict(pageInfo=dict(hasNextPage=False),nodes=[self.node(7)])))))
        self.write_pr()

    def tearDown(self):
        self.temporary.cleanup()

    def node(self, number, repo='owner/consumer', state='OPEN'):
        return dict(__typename='Issue',number=number,state=state,closedAt=None,url='https://github.com/'+repo+'/issues/'+str(number),repository=dict(nameWithOwner=repo))

    def mode(self, value):
        (self.root/'mode').write_text(value)

    def write_state(self):
        (self.root/'state').write_text(json.dumps(self.state))

    def write_pr(self):
        (self.root/'pr').write_text(json.dumps(self.pr))

    def run_helper(self, *extra):
        p = subprocess.run([sys.executable,str(HELPER),'--repo','owner/consumer','--pr','20',*extra],env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(p.stderr,'')
        if p.returncode < 0:
            return p.returncode, None
        result = json.loads(p.stdout)
        self.assertEqual(result['owner_repo'],'owner/consumer')
        return p.returncode, result

    def complete(self, *extra):
        return self.run_helper('--complete-issue','7','--scope-verified','--expected-merge',MERGE,*extra)

    def writes(self):
        return json.loads((self.root/'state').read_text())['writes']

    def test_audit_does_not_close_and_verifies_existing_closure(self):
        rc,x=self.run_helper();self.assertEqual(rc,1);self.assertEqual(self.writes(),0)
        self.assertEqual(x['issues'][0]['disposition'],'scope_verification_required')
        self.state['state']='CLOSED';self.write_state()
        rc,x=self.run_helper();self.assertEqual(rc,0);self.assertEqual(x['outcome'],'verified')

    def test_single_issue_completion_and_duplicate_resume(self):
        rc,x=self.complete();self.assertEqual(rc,0);self.assertEqual(self.writes(),1)
        self.assertEqual(x['issues'][0]['state'],'CLOSED')
        path=Path(x['receipt_path']);self.assertEqual(path.stat().st_mode&0o777,0o600)
        self.assertEqual(json.loads(path.read_text())['outcome'],'verified')
        rc,x=self.complete();self.assertEqual(rc,0);self.assertEqual(self.writes(),1)

    def test_incomplete_scope_and_wrong_merge_never_close(self):
        for options in [[],['--expected-merge',MERGE],['--scope-verified'],['--scope-verified','--expected-merge','c'*40]]:
            with self.subTest(options=options):
                rc,x=self.run_helper('--complete-issue','7',*options);self.assertEqual(rc,3);self.assertEqual(self.writes(),0)

    def test_unmerged_nondefault_or_foreign_author_never_close(self):
        pr=self.pr['data']['repository']['pullRequest']
        for field,value in [('state','OPEN'),('baseRefName','integration'),('author',dict(login='other'))]:
            previous=pr[field];pr[field]=value;self.write_pr()
            with self.subTest(field=field):
                rc,x=self.complete();self.assertEqual(rc,3);self.assertEqual(self.writes(),0)
            pr[field]=previous

    def test_unselected_linked_issue_remains_pending(self):
        pr=self.pr['data']['repository']['pullRequest'];pr['closingIssuesReferences']['nodes'].append(self.node(8));self.write_pr()
        rc,x=self.complete();self.assertEqual(rc,1);self.assertEqual(self.writes(),1)
        self.assertEqual(x['outcome'],'pending');self.assertEqual(x['issues'][1]['state'],'OPEN')

    def test_same_number_foreign_repo_not_selected(self):
        pr=self.pr['data']['repository']['pullRequest'];pr['closingIssuesReferences']['nodes']=[self.node(7,'other/repo')];self.write_pr()
        rc,x=self.complete();self.assertEqual(rc,3);self.assertEqual(self.writes(),0)
        self.assertEqual(x['issues'][0]['disposition'],'foreign_retained')

    def test_missing_trailer_requires_explicit_association(self):
        self.pr['data']['repository']['pullRequest']['closingIssuesReferences']['nodes']=[];self.write_pr()
        rc,x=self.complete();self.assertEqual(rc,3);self.assertEqual(self.writes(),0)
        rc,x=self.complete('--association-verified');self.assertEqual(rc,0);self.assertEqual(self.writes(),1)

    def test_api_write_and_delayed_verification_fail_recoverably(self):
        for mode,expected in [('api-error',4),('invalid-json',4),('write-error',4),('wrong-type',3),('delayed',1)]:
            with self.subTest(mode=mode):
                self.state.update(state='OPEN',writes=0);self.write_state();self.mode(mode)
                rc,x=self.complete();self.assertEqual(rc,expected);self.assertEqual(x['outcome'],'pending')
                self.assertTrue(Path(x['receipt_path']).is_file())
                self.mode('normal');rc,x=self.complete();self.assertEqual(rc,0)
                self.assertEqual(self.writes(),1)

    def test_interruption_after_close_preserves_intent_and_resumes(self):
        self.mode('interrupted');rc,x=self.complete();self.assertLess(rc,0);self.assertEqual(self.writes(),1)
        receipts=list(self.home.rglob('pr-20.issue-7.json'));self.assertEqual(len(receipts),1)
        self.assertEqual(json.loads(receipts[0].read_text())['issues'][0]['disposition'],'closure_pending')
        self.mode('normal');rc,x=self.complete();self.assertEqual(rc,0);self.assertEqual(self.writes(),1)

    def test_intentionally_reopened_issue_is_not_reclosed(self):
        self.mode('reopened');rc,x=self.complete();self.assertEqual(rc,3);self.assertEqual(self.writes(),0)
        self.assertEqual(x['error_class'],'issue_reopened_after_merge')

    def test_actual_workflow_adapter_scopes_pending_state_and_resume(self):
        reference = HELPER.parents[2] / 'reference/issue-completion.md'
        body = reference.read_text().split('<!-- test-anchor: issue-completion-record -->', 1)[1]
        fence = body.split('```bash\n', 1)[1].split('```', 1)[0]
        repo = self.root/'consumer'; repo.mkdir()
        subprocess.run(['git','init','-q',str(repo)],check=True,capture_output=True)
        subprocess.run(['git','-C',str(repo),'remote','add','origin','https://github.com/owner/consumer.git'],check=True,capture_output=True)
        script_dir = HELPER.parents[1]
        harness = '''resolve_script() { printf '%s/%s\\n' "$COMPLETION_SCRIPT_DIR" "$1"; }
'''
        harness += fence + '''
reconcile_issue_completion "$@"
result=$?
printf '%s\\n' "$COMPLETION_JSON"
exit "$result"
'''
        env = dict(self.env, COMPLETION_SCRIPT_DIR=str(script_dir), OWNER_REPO='owner/consumer', PR_NUM='20')
        for mode, expected in [('normal',1),('api-error',4)]:
            self.mode(mode)
            result = subprocess.run(['bash','-c',harness,'completion'],cwd=repo,env=env,text=True,capture_output=True,timeout=15)
            self.assertEqual(result.returncode,expected,result.stderr)
            state=json.loads((self.home/'.claude/session-state.json').read_text())
            record=state['repos']['owner/consumer']['prs']['20']['issue_completion']
            self.assertEqual(record['outcome'],'pending')
            self.assertNotIn('prs',state)
            if mode=='normal':
                state['repos']['other/repo']={'prs':{'20':{'phase':'A','sentinel':'foreign'}}}
                state['repos']['owner/consumer']['prs']['99']={'phase':'B','sentinel':'unrelated'}
                (self.home/'.claude/session-state.json').write_text(json.dumps(state))
            else:
                self.assertEqual(state['repos']['other/repo']['prs']['20']['sentinel'],'foreign')
                self.assertEqual(state['repos']['owner/consumer']['prs']['99']['sentinel'],'unrelated')
        self.mode('normal'); self.state['state']='CLOSED'; self.write_state()
        result=subprocess.run(['bash','-c',harness,'completion'],cwd=repo,env=env,text=True,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        state=json.loads((self.home/'.claude/session-state.json').read_text())
        self.assertEqual(state['repos']['owner/consumer']['prs']['20']['issue_completion']['outcome'],'verified')
        self.assertEqual(self.writes(),0)
        before=(self.home/'.claude/session-state.json').read_bytes()
        result=subprocess.run(['bash','-c',harness,'completion'],cwd=repo,
                              env=dict(env,OWNER_REPO='other/repo'),text=True,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,3)
        self.assertEqual((self.home/'.claude/session-state.json').read_bytes(),before)

    def test_final_handoff_publication_is_guarded_and_keeps_pending_work(self):
        rc,report=self.complete();self.assertEqual(rc,0)
        scripts=HELPER.parents[1];helper=scripts/'handoff-state.sh'
        initial=dict(pr_number=20,owner_repo='owner/consumer',head_sha='b'*40,phase_completed='B',worktree=str(self.root/'checkout'))
        subprocess.run([str(helper),'--owner-repo','owner/consumer','--init','20',json.dumps(initial)],env=self.env,check=True,capture_output=True)
        handoff=self.home/'.claude/handoffs/owner/consumer/pr-20-handoff.json'
        source=(HELPER.parents[2]/'reference/issue-completion.md').read_text()
        fence=source.split('<!-- test-anchor: issue-completion-publish -->',1)[1].split(chr(96)*3+'bash\n',1)[1].split(chr(96)*3,1)[0]
        harness="""resolve_script() { printf '%s/%s\\n' "$COMPLETION_SCRIPT_DIR" "$1"; }
""" + fence + '\npublish_completed_handoff\n'
        env=dict(self.env,COMPLETION_SCRIPT_DIR=str(scripts),PR_NUM='20',OWNER_REPO='owner/consumer',HEAD_SHA='b'*40)
        before=handoff.read_bytes()
        for invalid in [dict(report,outcome='pending'),dict(report,head_sha='c'*40),dict(report,outcome='retained',retained_scope={}),dict(report,error_class='github_unavailable')]:
            p=subprocess.run(['bash','-c',harness],env=dict(env,COMPLETION_JSON=json.dumps(invalid)),text=True,capture_output=True,timeout=15)
            self.assertEqual(p.returncode,3);self.assertEqual(handoff.read_bytes(),before)
        p=subprocess.run(['bash','-c',harness],env=dict(env,COMPLETION_JSON=json.dumps(report)),text=True,capture_output=True,timeout=15)
        self.assertEqual(p.returncode,0,p.stderr)
        recorded=json.loads(handoff.read_text());self.assertEqual(recorded['phase_completed'],'C')
        self.assertEqual(recorded['issue_completion']['outcome'],'verified')
        handoff.unlink()
        p=subprocess.run(['bash','-c',harness],env=dict(env,COMPLETION_JSON=json.dumps(report)),text=True,capture_output=True,timeout=15)
        self.assertNotEqual(p.returncode,0);self.assertFalse(handoff.exists())

    def test_unsafe_receipt_lock_is_refused_without_github_calls(self):
        directory=self.home/'.claude/issue-completion/github.com/owner/consumer'
        directory.mkdir(parents=True,mode=0o700)
        victim=self.root/'unrelated';victim.write_text('preserve')
        lock=directory/'pr-20.issue-7.json.lock';lock.symlink_to(victim)
        rc,result=self.complete()
        self.assertEqual(rc,6)
        self.assertEqual(result['outcome'],'pending')
        self.assertEqual(victim.read_text(),'preserve')
        self.assertFalse((self.root/'calls').exists())

    def test_null_or_wrong_repository_response_never_closes(self):
        repository=self.pr['data']['repository']
        for value in [None,dict(repository,nameWithOwner='other/repo')]:
            with self.subTest(value=value):
                self.pr['data']['repository']=value;self.write_pr()
                rc,result=self.complete();self.assertIn(rc,[3,4])
                self.assertEqual(result['outcome'],'pending')
                self.assertEqual(self.writes(),0)
        self.pr['data']['repository']=repository

    def test_truncated_associations_fail_closed(self):
        self.pr['data']['repository']['pullRequest']['closingIssuesReferences']['pageInfo']['hasNextPage']=True;self.write_pr()
        rc,x=self.complete();self.assertEqual(rc,3);self.assertEqual(self.writes(),0)


if __name__ == '__main__':
    unittest.main()
