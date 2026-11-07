#!/usr/bin/env bash
# catalog: tests — Finished-only worktree cleanup against disposable repos, remote proof, liveness and removal-race controls
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
real_git = shutil.which('git')
checks = 0
module_spec = importlib.util.spec_from_file_location('finished_cleanup_fixture', source/'.claude/scripts/lib/stale-cleanup-finished.py')
module = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(module)


def verify(value, message):
    global checks
    assert value, message
    checks += 1


for raw,expected in [('600',300),('nonsense',60),('-1',60)]:
    os.environ['FINISHED_FIXTURE_BOUND']=raw
    verify(module.bound('FINISHED_FIXTURE_BOUND',60)==expected,'finite timeout clamps/defaults '+raw)
os.environ.pop('FINISHED_FIXTURE_BOUND',None)

with tempfile.TemporaryDirectory(prefix='finished-cleanup-test-') as directory:
    tmp = Path(directory)
    root, bare, bin_dir = tmp/'repo', tmp/'remote.git', tmp/'bin'
    root.mkdir()
    bin_dir.mkdir()
    env = dict(os.environ, HOME=str(tmp/'home'), GIT_CONFIG_NOSYSTEM='1',
               GIT_CONFIG_GLOBAL=os.devnull, FINISHED_TEST_DB=str(tmp/'prs.json'),
               FINISHED_TEST_REMOTE=str(bare), FINISHED_TEST_LOG=str(tmp/'git.log'),
               FINISHED_TEST_CENSUS=str(tmp/'census-count'), FINISHED_TEST_SAFE_CWD=str(tmp),
               FINISHED_TEST_REAL_GIT=real_git)
    Path(env['HOME']).mkdir()
    env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']

    def git(*args, cwd=root, check=True, extra=None):
        run = subprocess.run([real_git, '-C', str(cwd), *args], env=dict(env, **(extra or {})),
                             text=True, capture_output=True, check=check)
        return run.stdout.strip()

    skill = (source/'.claude/skills/pm-clean/SKILL.md').read_text()
    refresh = skill.split('<!-- test-anchor: finished-workspace-refresh -->',1)[1].split('```bash\n',1)[1].split('\n```',1)[0]
    refresher = tmp/'refresh.sh'
    refresher.write_text("""#!/usr/bin/env bash
printf '%s\\n' '{"stale_worktrees":[],"fresh":true}'
exit 1
""")
    refresher.chmod(0o755)
    for applied,expected in [({'finished_apply':[{'removal_attempted':True,'worktree_removed':True}]},True),
                             ({'finished_apply':[{'removal_attempted':True,'outcome':'failed'}]},True),
                             ({'finished_apply':[]},False)]:
        result = subprocess.run(['bash','-c',refresh+"""
printf '%s\\n%s' "$RC" "$WORKSPACE_JSON"
"""],
            env=dict(env,FINISHED_APPLY_JSON=json.dumps(applied),RC='0',WORKSPACE_JSON='{"old":true}',
                     WORKTREE_DAYS='30',STALE_CLEANUP_SH=str(refresher)),text=True,capture_output=True)
        lines=result.stdout.splitlines()
        verify(result.returncode==0 and bool(json.loads(lines[1]).get('fresh'))==expected and lines[0]==('1' if expected else '0'), 'actual refresh block replaces JSON/RC only after removal attempts')

    git('init', '-q', '-b', 'main')
    git('config', 'user.name', 'Fixture')
    git('config', 'user.email', 'fixture@example.invalid')
    (root/'README').write_text('fixture\n', encoding='utf-8')
    (root/'.gitignore').write_text('.env\n.DS_Store\n', encoding='utf-8')
    git('add', 'README', '.gitignore')
    git('commit', '-qm', 'base')
    git('init', '--bare', '-q', str(bare))
    git('remote', 'add', 'push-fixture', str(bare))
    git('remote', 'add', 'origin', 'https://github.com/fixture/repo.git')

    # Stub network/proc reads, but run the actual git operations and authorship guard.
    (bin_dir/'gh').write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]; db=json.loads(Path(os.environ['FINISHED_TEST_DB']).read_text())
if db.get('fail'): print('fixture API unavailable',file=sys.stderr);sys.exit(1)
if a[:2]==['api','user']: print('fixture-owner');sys.exit(0)
if a and a[0]=='api':
 n=int(a[1].split('/')[-1]); row=next(r for r in db['rows'] if r['number']==n)
 print(json.dumps({'user':{'login':row.get('author','fixture-owner'),'type':'User'},'state':row['state'].lower()}));sys.exit(0)
if a[:2]==['pr','list']:
 head=a[a.index('--head')+1] if '--head' in a else None
 rows=[r for r in db['rows'] if head is None or r['headRefName']==head]
 opened=('--state' in a and a[a.index('--state')+1]=='open') or '--search' in a
 if head and opened and db.get('reopen')==head:
  count=Path(os.environ['FINISHED_TEST_DB']+'.open-count'); n=int(count.read_text())+1 if count.exists() else 1; count.write_text(str(n))
  if n>=2: rows=[dict(rows[0],state='OPEN')]
 if head=='env-race' and not opened and os.environ.get('FINISHED_TEST_ENV_ON_LOOKUP'):
  count=Path(os.environ['FINISHED_TEST_DB']+'.env-count'); n=int(count.read_text())+1 if count.exists() else 1;count.write_text(str(n))
  if n>=2:Path(os.environ['FINISHED_TEST_ENV_ON_LOOKUP'],'.env').write_text('fixture only')
 if opened: rows=[r for r in rows if r['state']=='OPEN']
 print(json.dumps(rows));sys.exit(0)
print('unexpected gh probe',a,file=sys.stderr);sys.exit(2)
''', encoding='utf-8')
    (bin_dir/'git').write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys,time
from pathlib import Path
a=sys.argv[1:]
with open(os.environ['FINISHED_TEST_LOG'],'a') as f:f.write(json.dumps(a)+'\\n')
if 'ls-remote' in a and 'origin' in a: a[a.index('origin')]=os.environ['FINISHED_TEST_REMOTE']
if 'branch' in a and '-d' in a and os.environ.get('FINISHED_TEST_REF_RACE'):
 base=a[a.index('-C')+1]; ref='refs/heads/'+a[-1]; real=os.environ['FINISHED_TEST_REAL_GIT']; old=subprocess.check_output([real,'-C',base,'rev-parse',ref],text=True).strip()
 tree=subprocess.check_output([real,'-C',base,'rev-parse',old+'^{tree}'],text=True).strip()
 new=subprocess.check_output([real,'-C',base,'commit-tree',tree,'-p',old,'-m','concurrent local work'],text=True).strip()
 subprocess.run([real,'-C',base,'update-ref',ref,new,old],check=True)
 Path(os.environ['FINISHED_TEST_REF_RACE']).write_text(new)
if 'branch' in a and '-d' in a and os.environ.get('FINISHED_TEST_ATOMIC_RACE'):
 # Model a ref advancing after Git's merge check: bypass that earlier check
 # only in this disposable fixture. The serialized expected-tip guard must
 # still veto deletion of the new commit at transaction preparation.
 base=a[a.index('-C')+1];ref='refs/heads/'+a[-1];real=os.environ['FINISHED_TEST_REAL_GIT']
 old=subprocess.check_output([real,'-C',base,'rev-parse',ref],text=True).strip()
 tree=subprocess.check_output([real,'-C',base,'rev-parse',old+'^{tree}'],text=True).strip()
 new=subprocess.check_output([real,'-C',base,'commit-tree',tree,'-p',old,'-m','late unpublished work'],text=True).strip()
 subprocess.run([real,'-C',base,'update-ref',ref,new,old],check=True)
 Path(os.environ['FINISHED_TEST_ATOMIC_RACE']).write_text(new)
 a[a.index('-d')]='-D'
if 'branch' in a and '-d' in a and os.environ.get('FINISHED_TEST_CHECKOUT_RACE'):
 base=a[a.index('-C')+1];real=os.environ['FINISHED_TEST_REAL_GIT']
 subprocess.run([real,'-C',base,'worktree','add','-q',os.environ['FINISHED_TEST_CHECKOUT_RACE'],a[-1]],check=True)
if 'worktree' in a and 'remove' in a and os.environ.get('FINISHED_TEST_REMOVE_HANG'):time.sleep(3)
if 'worktree' in a and 'remove' in a and os.environ.get('FINISHED_TEST_REMOVE_RACE'):
 Path(a[-1],'.DS_Store').write_text('fixture race')
 print('fatal: Directory not empty',file=sys.stderr);sys.exit(1)
sys.exit(subprocess.run([os.environ['FINISHED_TEST_REAL_GIT'],*a]).returncode)
''', encoding='utf-8')
    (bin_dir/'ps').write_text('''#!/usr/bin/env python3
import os
print('/Applications/Codex.app/Contents/MacOS/Codex' if os.environ.get('FINISHED_TEST_DESKTOP') else '/usr/bin/bash')
''', encoding='utf-8')
    (bin_dir/'lsof').write_text('''#!/usr/bin/env python3
import os,sys,time,subprocess
from pathlib import Path
if os.environ.get('FINISHED_TEST_LSOF_FAIL'):print('partial process visibility',file=sys.stderr);sys.exit(1)
if os.environ.get('FINISHED_TEST_LSOF_EMPTY'):sys.exit(0)
if os.environ.get('FINISHED_TEST_LSOF_HANG'):time.sleep(3)
count=Path(os.environ['FINISHED_TEST_CENSUS']); n=int(count.read_text())+1 if count.exists() else 1;count.write_text(str(n))
cwd=os.environ.get('FINISHED_TEST_CWD') or os.environ['FINISHED_TEST_SAFE_CWD']
if os.environ.get('FINISHED_TEST_LIVE_ON_APPLY') and n>=2:cwd=os.environ['FINISHED_TEST_LIVE_ON_APPLY']
if os.environ.get('FINISHED_TEST_COMMIT_ON_APPLY') and n>=2:
 target=Path(os.environ['FINISHED_TEST_COMMIT_ON_APPLY']);(target/'README').write_text('committed during verification')
 subprocess.run([os.environ['FINISHED_TEST_REAL_GIT'],'-C',str(target),'commit','-qam','concurrent work'],check=True)
if os.environ.get('FINISHED_TEST_ENV_AFTER_CENSUS') and n>=2:
 Path(os.environ['FINISHED_TEST_ENV_AFTER_CENSUS'],'.env').write_text('fixture only')
print('p100\\nn'+cwd)
''', encoding='utf-8')
    for script in bin_dir.iterdir():
        script.chmod(0o755)
    db = {'rows': []}

    def write_db():
        Path(env['FINISHED_TEST_DB']).write_text(json.dumps(db), encoding='utf-8')

    def worktree(name, state='MERGED', old=False, location=None):
        path = location or tmp/('wt-'+name)
        git('worktree', 'add', '-q', '-b', name, str(path))
        (path/'README').write_text(name+'\n', encoding='utf-8')
        git('add', 'README', cwd=path)
        dates = {'GIT_AUTHOR_DATE':'2020-01-05T00:00:00Z','GIT_COMMITTER_DATE':'2020-01-05T00:00:00Z'} if old else None
        git('commit', '-qm', name, cwd=path, extra=dates)
        git('push', '-q', 'push-fixture', name)
        head = git('rev-parse', 'HEAD', cwd=path)
        if state:
            db['rows'].append(dict(number=len(db['rows'])+1, state=state, headRefName=name,
                                   headRefOid=head, isCrossRepository=False, createdAt='2026-11-07T00:00:00Z'))
        write_db()
        return path

    script = str(source/'.claude/scripts/stale-cleanup.sh')

    def sweep(mode='--check', cwd=root, extra=None, flags=()):
        effective = dict(env, STALE_DAYS='30', **(extra or {}))
        run = subprocess.run(['bash', script, mode, '--root', str(root), '--json', *flags],
                             cwd=cwd, env=effective, text=True, capture_output=True, timeout=90)
        try:
            data = json.loads(run.stdout)
        except ValueError as exc:
            raise AssertionError((run.returncode, run.stdout, run.stderr)) from exc
        return run.returncode, data

    young = worktree('young')
    closed = worktree('closed', 'CLOSED')
    dirty = worktree('dirty'); (dirty/'README').write_text('changed tracked contents\n')
    untracked = worktree('untracked'); (untracked/'scratch').write_text('untracked\n')
    unpushed = worktree('unpushed'); (unpushed/'README').write_text('not pushed\n');git('commit','-qam','local only',cwd=unpushed)
    opened = worktree('opened','OPEN')
    locked = worktree('locked');git('worktree','lock',str(locked))
    live = worktree('live');(live/'child').mkdir()
    protected = worktree('dotenv');(protected/'.env').write_text('fixture only\n')
    foreign = worktree('foreign');next(r for r in db['rows'] if r['headRefName']=='foreign')['author']='someone-else';write_db()
    old = worktree('old-unmerged',None,old=True)
    managed = worktree('managed',location=tmp/'.codex/worktrees/managed')
    code, data = sweep(extra={'FINISHED_TEST_CWD':str(live/'child')})
    eligible = {r['branch'] for r in data['finished_worktrees']}
    skipped = {r['branch']:r['reason'] for r in data['skipped_finished_worktrees']}
    verify({'young','closed'} <= eligible, 'recent merged/closed PRs are finished independently of age')
    verify(all(r['branch'] not in ('young','closed') for r in data['stale_worktrees']), 'young finished trees are not age candidates')
    for branch, reason in [('dirty','uncommitted_tracked_changes'),('untracked','untracked_files'),
                           ('unpushed','unpushed_commits'),('opened','open_pr'),('locked','locked'),
                           ('live','live_process'),('dotenv','protected_env_files'),('foreign','not_authored')]:
        verify(skipped.get(branch)==reason, (branch, skipped))
    verify(any(r['branch']=='managed' and r['reason']=='desktop_session_liveness_unknown' for r in data['unknown_finished_worktrees']), 'managed desktop liveness remains unknown')
    code, data = sweep(cwd=young)
    verify(any(r['branch']=='young' and r['reason']=='caller_worktree' for r in data['skipped_finished_worktrees']), 'caller worktree is protected')
    verify(any(r['reason']=='main_worktree' for r in data['skipped_finished_worktrees']), 'main worktree is protected')
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_CWD':str(live/'child')})
    verify(not young.exists() and not closed.exists(), 'finished mode removes both verified trees')
    verify(git('branch','--list','young')=='', ('finished local branch removed',data.get('finished_apply'),data.get('unknown_finished_worktrees')))
    verify(git('--git-dir',str(bare),'rev-parse','refs/heads/young')!='', 'remote branch stays intact')
    verify(old.exists() and git('branch','--list','old-unmerged')!='', 'finished mode never reaches age-only apply')
    verify(all(path.exists() for path in [dirty,untracked,unpushed,opened,locked,live,protected,foreign,managed]), 'every unsafe/unknown worktree retained')

    # Initial safety assertions above have already exercised every negative
    # control. Lock them now to avoid repeating expensive unrelated probes.
    for negative in [dirty,untracked,unpushed,opened,live,protected,foreign,old]:
        git('worktree','lock',str(negative))

    # Leave a single clean candidate for revalidation and unavailable-probe cases.
    candidate = worktree('race')
    for option in ['FINISHED_TEST_LSOF_FAIL','FINISHED_TEST_LSOF_EMPTY','FINISHED_TEST_DESKTOP']:
        code, data = sweep('--apply-finished',extra={option:'1'})
        verify(candidate.exists() and data['finished_scan']=='incomplete', option+' fails closed')
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_LSOF_HANG':'1','STALE_CLEANUP_LSOF_TIMEOUT_SECS':'0.5'})
    verify(candidate.exists() and data['finished_scan']=='incomplete', 'bounded hanging census never authorizes removal')
    db['fail']=True;write_db()
    code, data = sweep('--apply-finished')
    verify(code!=0 and candidate.exists() and data['unknown_finished_worktrees'], 'GitHub failure is reported unknown and retained')
    code, data = sweep()
    verify(code==4 and data['finished_scan']=='incomplete', 'legacy open-PR failure also exposes unknown finished report')
    db.pop('fail');write_db()
    # Exclude other eligible non-live tree while isolating the single candidate.
    db['reopen']='race';write_db()
    code, data = sweep('--apply-finished')
    verify(candidate.exists() and any(r['branch']=='race' and r['reason']=='open_pr' for r in data.get('finished_apply',[])), 'new open PR before removal prevents apply')
    db.pop('reopen');write_db()
    Path(env['FINISHED_TEST_CENSUS']).unlink(missing_ok=True)
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_LIVE_ON_APPLY':str(candidate)})
    verify(candidate.exists(), 'fresh cwd census catches live session before remove')
    Path(env['FINISHED_TEST_CENSUS']).unlink(missing_ok=True)
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_COMMIT_ON_APPLY':str(candidate)})
    verify(candidate.exists() and any(r['branch']=='race' and r['reason']=='head_changed_before_remove' for r in data['unknown_finished_worktrees']), 'commit during slow probes is caught before worktree removal')
    git('push','-q','push-fixture','race')
    next(r for r in db['rows'] if r['headRefName']=='race')['headRefOid']=git('rev-parse','HEAD',cwd=candidate);write_db()
    env_race = worktree('env-race')
    git('worktree','lock',str(candidate))
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_ENV_ON_LOOKUP':str(env_race)})
    verify(env_race.exists() and (env_race/'.env').exists() and any(r['branch']=='env-race' and r['reason']=='protected_env_files' for r in data.get('finished_apply',[])), 'protected file created during remote lookup is rechecked before removal')
    late_env = worktree('late-env')
    Path(env['FINISHED_TEST_CENSUS']).unlink(missing_ok=True)
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_ENV_AFTER_CENSUS':str(late_env)})
    verify(late_env.exists() and (late_env/'.env').exists() and any(r['branch']=='late-env' and r['reason']=='protected_env_files' for r in data.get('finished_apply',[])), 'ignored protected file created during final census is retained')
    git('worktree','unlock',str(candidate))
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_REMOVE_HANG':'1','STALE_CLEANUP_REMOVE_TIMEOUT_SECS':'0.5'})
    verify(candidate.exists() and any(r['branch']=='race' and r['outcome']=='failed' and r.get('removal_attempted') for r in data.get('finished_apply',[])), 'timed-out removal is a failed attempt rather than a clean skip')
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_REMOVE_RACE':'1'})
    failed = [r for r in data.get('finished_apply',[]) if r['branch']=='race']
    verify(candidate.exists() and failed and failed[0]['outcome']=='failed', 'directory-not-empty never force deletes')
    verify('.DS_Store' in failed[0].get('remaining_entries',''), 'remaining path is listed for directory-not-empty')
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_REF_RACE':str(tmp/'new-ref')})
    new_ref = (tmp/'new-ref').read_text().strip()
    verify(not candidate.exists() and git('rev-parse','refs/heads/race')==new_ref, 'pinned upstream merge test retains a concurrent new commit')
    verify(any(r['branch']=='race' and r['outcome']=='failed' and r.get('worktree_removed') for r in data.get('finished_apply',[])), 'partial removal with retained branch is reported')
    checkout_candidate = worktree('checkout-race')
    replacement = tmp/'new-live-checkout'
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_CHECKOUT_RACE':str(replacement)})
    verify(not checkout_candidate.exists() and replacement.exists() and git('branch','--list','checkout-race')!='', 'Git branch deletion refuses a new concurrent checkout')
    verify(git('for-each-ref','--format=%(refname)','refs/claude/finished-cleanup')=='', 'temporary pinned upstream refs are removed')
    atomic_candidate = worktree('atomic-race')
    atomic_marker = tmp/'atomic-new-ref'
    code, data = sweep('--apply-finished',extra={'FINISHED_TEST_ATOMIC_RACE':str(atomic_marker)})
    late_tip = atomic_marker.read_text().strip()
    verify(not atomic_candidate.exists() and git('rev-parse','refs/heads/atomic-race',check=False)==late_tip, 'serialized expected-tip guard retains a commit after the earlier merge test')

    # Run actual owner hooks through the guarded deletion, including a path
    # with spaces and inherited command config. An owner veto stays binding.
    hooks = tmp/'owner hooks'; hooks.mkdir()
    hook_log = tmp/'owner-hook.jsonl'
    hook = hooks/'reference-transaction'
    hook.write_text('''#!/usr/bin/env python3
import json,os,subprocess,sys
payload=sys.stdin.read();stage=sys.argv[1]
def config(key):
 return subprocess.check_output(['git','config','--get',key],text=True).strip()
with open(os.environ['FINISHED_OWNER_HOOK_LOG'],'a') as stream:
 stream.write(json.dumps({'stage':stage,'payload':payload,'hooks_path':config('core.hooksPath'),'setting':config('fixture.setting')})+'\\n')
if stage=='prepared' and any(line.split()[-1]=='refs/heads/owner-veto' and set(line.split()[1])=={'0'} for line in payload.splitlines()):sys.exit(1)
''')
    hook.chmod(0o755)
    env['FINISHED_OWNER_HOOK_LOG'] = str(hook_log)
    env['GIT_CONFIG_PARAMETERS'] = "'fixture.setting'='owner'"
    git('config','core.hooksPath',str(hooks))
    allowed = worktree('owner-allowed')
    code, data = sweep('--apply-finished')
    verify(not allowed.exists() and not git('branch','--list','owner-allowed'), 'existing owner hook permits normal guarded deletion')
    vetoed = worktree('owner-veto')
    code, data = sweep('--apply-finished')
    verify(not vetoed.exists() and bool(git('branch','--list','owner-veto')), 'existing owner hook veto retains branch and reports partial removal')
    verify(any(r['branch']=='owner-veto' and r['outcome']=='failed' and r.get('worktree_removed') for r in data.get('finished_apply',[])), 'owner veto is never reported as a successful branch deletion')
    rows = [json.loads(row) for row in hook_log.read_text().splitlines()]
    verify(rows and all(row['hooks_path']==str(hooks) and row['setting']=='owner' for row in rows), 'owner hook sees original hooks path and inherited config')
    verify(all(any(row['stage']==stage and 'refs/heads/owner-allowed' in row['payload'] for row in rows) for stage in ['prepared','committed']), 'owner hook receives transaction lifecycle and stdin')
    git('config','--unset','core.hooksPath')
    env.pop('GIT_CONFIG_PARAMETERS')
    log = Path(env['FINISHED_TEST_LOG']).read_text()
    verify('"clean"' not in log and '"--force"' not in log, 'no git clean or forced worktree remove')
    bad = subprocess.run(['bash',script,'--apply-finished','--apply'],cwd=root,env=env,capture_output=True)
    verify(bad.returncode==3, 'finished mode cannot combine with legacy apply')
    bad = subprocess.run(['bash',script,'--apply-finished','--include-locked'],cwd=root,env=env,capture_output=True)
    verify(bad.returncode==3, 'finished mode cannot bypass a lock')
print(f'{checks} finished-cleanup safety checks passed; only disposable fixture worktrees were removed.')
PY
