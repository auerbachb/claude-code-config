#!/bin/bash
# catalog: tests — Exercise finished-worktree cadence with real disposable Git cleanup and extracted orchestration commands
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1])
# Reuse the existing offline fixture bootstrap, including its fake gh/process
# boundary and real bare Git remote. Stop before its independent test cases.
fixture = (source/'.claude/scripts/tests/stale-cleanup-finished.test.sh').read_text()
bootstrap = fixture.split("<<'PY'\n",1)[1].split("    young = worktree('young')",1)[0]
assert 'def worktree(' in bootstrap and 'def sweep(' in bootstrap
cases = r'''
    import concurrent.futures
    import time
    runner = source/'.claude/scripts/workspace-sweep.sh'
    actual_cleanup = script
    recorder = tmp/'cleanup-recorder.sh'
    recorder.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CADENCE_CALLS"\nexec /bin/bash "$CADENCE_REAL" "$@"\n')
    recorder.chmod(0o755)
    env.update(WORKSPACE_SWEEP_CLEANUP_SH=str(recorder), CADENCE_CALLS=str(tmp/'calls'), CADENCE_REAL=actual_cleanup)
    def cadence(*args, extra=None):
        return subprocess.run(['bash',str(runner),*args],cwd=root,env=dict(env,**(extra or {})),text=True,capture_output=True,timeout=120)
    def logs():
        return [json.loads(s) for s in (Path(env['HOME'])/'.claude/workspace-sweep/runs.jsonl').read_text().splitlines()]
    def calls():
        return (tmp/'calls').read_text().splitlines()
    def fence(file, anchor):
        extracted=subprocess.run(['bash','-c','source "$1"; extract_skill_bash "$2" "$3"','fixture',str(source/'.claude/scripts/tests/lib/skill-bash.sh'),str(source/file),anchor.removeprefix('# ').strip()],text=True,capture_output=True,check=True)
        return 'resolve_script() { printf "%s\\n" "$CADENCE_RUNNER"; }\n'+extracted.stdout
    merged=worktree('cadence-merged')
    active=worktree('cadence-active','OPEN');(active/'README').write_text('unfinished')
    block=fence('.claude/rules/phase-protocols.md','# workspace-sweep-post-merge\n')
    result=subprocess.run(['bash','-c',block],cwd=root,env=dict(env,CADENCE_RUNNER=str(runner)),text=True,capture_output=True,timeout=120)
    verify(result.returncode==0 and not result.stdout and not merged.exists(),'actual Phase C command silently reaps merged worktree')
    verify(active.exists() and root.exists(),'actual Phase C command protects unfinished and caller worktrees')
    verify(git('branch','--list','cadence-merged')=='','actual cleanup removes finished local branch')
    verify(logs()[-1]['removed']==1 and logs()[-1]['skipped_with_reason']>=1,'actual cleanup counts recorded')
    now=int(time.time())
    tick=fence('.claude/skills/pm/SKILL.md','# workspace-sweep-pm-day\n')
    for _ in range(2):
        result=subprocess.run(['bash','-c',tick],cwd=root,env=dict(env,CADENCE_RUNNER=str(runner)),text=True,capture_output=True,timeout=120)
        verify(result.returncode==0 and not result.stdout,'actual tick inside post-merge interval is silent')
    verify(len(calls())==1,'post-merge suppresses repeated PM ticks')
    base=Path(env['HOME'])/'.claude/workspace-sweep'
    state=next(base.glob('*.json'))
    state=next(p for p in base.glob('*.json') if p.name!='repos.json')
    # Routine SessionStart registration must survive a short registry writer.
    import fcntl
    fd=os.open(base/'registry.lock',os.O_RDWR);fcntl.flock(fd,fcntl.LOCK_EX)
    try:
        pending=subprocess.Popen(['bash',str(runner),'--register-repo',str(root),'--now',str(now+1)],cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        time.sleep(0.5)
        verify(pending.poll() is None,'registry registration waits for a routine concurrent writer')
    finally:
        os.close(fd)
    stdout,stderr=pending.communicate(timeout=10)
    verify(pending.returncode==0 and not stdout and all(v['seen']==now+1 for v in json.loads((base/'repos.json').read_text()).values()),'registration publishes after the short lock holder releases')
    state.write_text(json.dumps({'attempted_at':now-3600}));state.chmod(0o600)
    result=cadence('--trigger','pm-day','--repo-dir',str(root),'--now',str(now))
    verify(result.returncode==0 and len(calls())==2,'exact interval boundary permits sweep')
    for value in ['bad json', '{}', json.dumps({'attempted_at':now+1000})]:
        state.write_text(value)
        before=len(calls());result=cadence('--trigger','pm-day','--repo-dir',str(root),'--now',str(now))
        verify(result.returncode==0 and len(calls())==before+1,'missing malformed or future epoch permits sweep')
    state.write_text('{}')
    with concurrent.futures.ThreadPoolExecutor(2) as pool:
        before=len(calls())
        results=list(pool.map(lambda _:cadence('--trigger','pm-day','--repo-dir',str(root),'--now',str(now)),range(2)))
    verify(all(r.returncode==0 for r in results) and len(calls())==before+1,'concurrent ticks serialize to one sweep')
    verify(all('--apply-finished' in s and '--apply ' not in s for s in calls()),'cadence never calls age apply')
    second=tmp/'other';second.mkdir();git('init','-q','-b','main',cwd=second)
    git('config','user.name','Fixture',cwd=second);git('config','user.email','fixture@example.invalid',cwd=second)
    (second/'README').write_text('other');git('add','README',cwd=second);git('commit','-qm','base',cwd=second)
    git('remote','add','origin','https://github.com/fixture/other.git',cwd=second)
    explicit=Path(env['HOME'])/'.claude/workspace-sweep-repos';explicit.write_text(str(root)+'\n'+str(second)+'\n'+str(root)+'\n')
    before=len(logs());result=cadence('--trigger','daily','--configured')
    verify(result.returncode==0 and len(logs())==before+2,'configured daily job sweeps and logs both distinct repos')
    # Execute the installer's actual printed daily command against both repos.
    (bin_dir/'uname').write_text('#!/bin/sh\necho Darwin\n');(bin_dir/'uname').chmod(0o755)
    (bin_dir/'launchctl').write_text('#!/bin/sh\nexit 0\n');(bin_dir/'launchctl').chmod(0o755)
    import shlex
    dry=subprocess.run(['bash',str(source/'.claude/scripts/install-workspace-sweep.sh'),'--dry-run'],env=env,text=True,capture_output=True,check=True)
    manual=dry.stdout.split('# Manual command: ',1)[1].strip()
    before=len(logs());result=subprocess.run(shlex.split(manual),cwd=root,env=env,text=True,capture_output=True,timeout=120)
    verify(result.returncode==0 and len(logs())==before+2,'actual printed daily command sweeps both configured fixture repos')
    explicit.unlink()
    before=len(logs());result=cadence('--trigger','daily','--configured')
    verify(result.returncode==0 and len(logs())==before+2,'default recent registry discovers both repos without PM')
    # Recent session metadata bootstraps paths absent from the new registry.
    registry=base/'repos.json';saved=json.loads(registry.read_text())
    registry.write_text(json.dumps({k:v for k,v in saved.items() if v['path']!=str(second)}))
    from datetime import datetime,timezone
    session=Path(env['HOME'])/'.claude/session-state.json'
    session.write_text(json.dumps({'repos':{'identity-not-a-path':{'prs':{'7':{'root_repo':str(second),'last_cron_action':{'at':datetime.fromtimestamp(now,timezone.utc).isoformat()}}}}}}));session.chmod(0o600)
    before=len(logs());result=cadence('--trigger','daily','--configured')
    verify(result.returncode==0 and len(logs())==before+2,'recent session-state absolute paths seed default discovery without interpreting repo keys')
    result=cadence('--register-repo',str(active))
    verify(result.returncode==0 and all(v['path']!=str(active) for v in json.loads(registry.read_text()).values()),'registration persists stable main checkout instead of disposable feature tree')
    race=worktree('cadence-remove-race')
    result=cadence('--trigger','post-merge','--repo-dir',str(root),extra={'FINISHED_TEST_REMOVE_RACE':'1'})
    row=logs()[-1];evidence=Path(row['evidence'])
    verify(result.returncode==1 and race.exists() and row['action'],'refused removal keeps tree and produces actionable metadata')
    raw=json.loads((evidence/'stdout').read_text())
    verify(any('remaining_entries' in a and '.DS_Store' in a['remaining_entries'] for a in raw['finished_apply']),'refused-path listing is retained in private byte capture')
    # The fixture race was deliberately left intact; protect it from later runs.
    (race/'scratch').write_text('unfinished fixture work')
    broken=tmp/'old-path';explicit.write_text(str(broken)+'\n'+str(root)+'\n')
    before=len(logs());result=cadence('--trigger','daily','--configured')
    verify(result.returncode==1 and len(logs())==before+2 and 'needs attention' in result.stdout,'missing path logs action and does not prevent other repos')
    bad=tmp/'bad-cleanup.sh';bad.write_text('echo "{}"\n');env['WORKSPACE_SWEEP_CLEANUP_SH']=str(bad)
    before=state.read_bytes();result=cadence('--trigger','post-merge','--repo-dir',str(root))
    verify(result.returncode==1 and state.read_bytes()==before and 'interface' in result.stdout,'unsupported adapter never advances timestamp or performs fallback deletion')
    verify(logs()[-1]['removed'] is None and logs()[-1]['skipped_with_reason'] is None,'invalid final report cannot falsely claim zero partial removals')
    try:
        module_spec=importlib.util.spec_from_file_location('cadence_bound',source/'.claude/scripts/lib/workspace_sweep.py')
        cadence_module=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(cadence_module)
        timeout_row={}
        cadence_module.command(['bash','-c','echo partial; sleep 30'],timeout=0.1,evidence=base,record_row=timeout_row)
        raise AssertionError('timeout must fail')
    except subprocess.TimeoutExpired:
        capture=Path(timeout_row['evidence'])
        verify((capture/'stdout').read_text()=='partial\n' and json.loads((capture/'capture.json').read_text())['exception']=='TimeoutExpired','deadline retains partial evidence before raising unknown')
    verify(all((p.stat().st_mode & 0o077)==0 for p in base.rglob('*')),'all cadence state and raw evidence files stay private')
    verify(any(p.name=='stdout' for p in base.rglob('*')),'raw cleanup evidence survives subsequent invocations')
    print(str(checks)+' cadence checks passed')
'''
exec(compile(bootstrap+cases,'workspace-sweep-fixture','exec'))
PY
