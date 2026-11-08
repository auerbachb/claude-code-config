#!/bin/bash
# catalog: tests — Verify cadence artifact cleanup with disposable Git/files, terminal PRs, liveness, guarded publication and retention races
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1])
fixture=(source/'.claude/scripts/tests/stale-cleanup-finished.test.sh').read_text()
bootstrap=fixture.split("<<'PY'\n",1)[1].split("    young = worktree('young')",1)[0]
cases=r'''
    import time
    now=int(time.time())
    helper=source/'.claude/scripts/lib/workspace_artifacts.py'
    scratch_root=tmp/'scratch';scratch_root.mkdir(mode=0o700)
    env['WORKSPACE_SWEEP_SCRATCH_ROOTS_JSON']=json.dumps([str(scratch_root)])
    # The fixture has no network; extend its native gh boundary for numbered PR reads.
    gh=bin_dir/'gh';text=gh.read_text();text=text.replace("if a[:2]==['pr','list']:","if a[:2]==['pr','view']:\n row=next(r for r in db['rows'] if r['number']==int(a[2]));print(json.dumps(row));sys.exit(0)\nif a[:2]==['pr','list']:")
    gh.write_text(text)
    ps=bin_dir/'ps';text=ps.read_text();text=text.replace('import os\n',"import os,sys,subprocess\nif '-p' in sys.argv:sys.exit(subprocess.run(['/bin/ps',*sys.argv[1:]]).returncode)\n")
    ps.write_text(text)
    def artifacts(apply=True, extra=None, cursor=0):
        args=[sys.executable,str(helper),'--root',str(root),'--now',str(now),'--cursor',str(cursor)]
        if apply:args.append('--apply')
        result=subprocess.run(args,cwd=root,env=dict(env,**(extra or {})),text=True,capture_output=True,timeout=120)
        verify(result.returncode==0,('artifact CLI failed',result.stdout,result.stderr))
        return json.loads(result.stdout)
    def outcome(report,path):
        target=Path(path);wanted=str(target.resolve()) if target.is_absolute() else str(target)
        rows=[r for r in report['artifacts'] if (str(Path(r['path']).resolve()) if Path(r['path']).is_absolute() else r['path'])==wanted]
        assert len(rows)==1, (wanted,report)
        return rows[0]
    merged=worktree('artifact-merged');opened=worktree('artifact-open','OPEN')
    merged_row=next(r for r in db['rows'] if r['headRefName']=='artifact-merged')
    open_row=next(r for r in db['rows'] if r['headRefName']=='artifact-open')
    directory=Path(env['HOME'])/'.claude/handoffs/fixture/repo';directory.mkdir(parents=True)
    def handoff(row):
        path=directory/('pr-'+str(row['number'])+'-handoff.json')
        path.write_text(json.dumps(dict(pr_number=row['number'],owner_repo='fixture/repo',head_sha=row['headRefOid'],phase_completed='C',worktree=str(merged),issue_completion=dict(outcome='verified',owner_repo='fixture/repo',pr=row['number'],head_sha=row['headRefOid']))))
        path.chmod(0o600);return path
    finished_handoff=handoff(merged_row);open_handoff=handoff(open_row)
    result=artifacts(extra={'FINISHED_TEST_CWD':str(merged)})
    verify(finished_handoff.exists() and outcome(result,finished_handoff)['reason']=='live_process','live session keeps its completed handoff')
    saved=json.loads(finished_handoff.read_text())
    for label,update in [('phase',{'phase_completed':'B'}),('pending',{'issue_completion':dict(saved['issue_completion'],outcome='pending')}),('legacy',{'worktree':None}),('foreign-completion',{'issue_completion':dict(saved['issue_completion'],owner_repo='other/repo')}),('boolean-pr',{'issue_completion':dict(saved['issue_completion'],pr=True)}),('retained-without-proof',{'issue_completion':dict(saved['issue_completion'],outcome='retained',retained_scope='unchecked')})]:
        finished_handoff.write_text(json.dumps(dict(saved,**update)))
        result=artifacts()
        verify(finished_handoff.exists() and not outcome(result,finished_handoff)['removed'],'uncertain handoff retained: '+label)
    finished_handoff.write_text(json.dumps(saved))
    result=artifacts(extra={'FINISHED_TEST_DESKTOP':'1'})
    verify(finished_handoff.exists() and not outcome(result,finished_handoff)['removed'],'unknown desktop binding keeps handoff')
    result=artifacts(False)
    verify(finished_handoff.exists() and outcome(result,finished_handoff)['outcome']=='candidate','artifact report never deletes')
    result=artifacts()
    verify(not finished_handoff.exists() and outcome(result,finished_handoff)['removed'],'terminal scoped handoff is removed through guarded helper')
    verify(open_handoff.exists() and outcome(result,open_handoff)['reason']=='open_pr','open PR handoff retained')
    verify(outcome(result,finished_handoff)['logical_bytes_reclaimed']>0,'handoff bytes count only after actual deletion')

    reaped=worktree('handoff-reaped')
    reaped_row=next(r for r in db['rows'] if r['headRefName']=='handoff-reaped')
    reaped_handoff=handoff(reaped_row);doc=json.loads(reaped_handoff.read_text());doc['worktree']=str(reaped);reaped_handoff.write_text(json.dumps(doc))
    git('worktree','remove',str(reaped))
    result=artifacts()
    verify(not reaped_handoff.exists() and outcome(result,reaped_handoff)['removed'],'completed handoff of already reaped inactive checkout removed')

    released=worktree('unheld-finished');git('worktree','remove',str(released))
    open_released=worktree('unheld-open','OPEN');git('worktree','remove',str(open_released))
    advanced=worktree('unheld-advanced');(advanced/'README').write_text('unpublished');git('commit','-qam','new unpublished work',cwd=advanced);advanced_head=git('rev-parse','HEAD',cwd=advanced);git('worktree','remove',str(advanced))
    result=artifacts()
    verify(outcome(result,'unheld-finished')['removed'] and subprocess.run([real_git,'-C',str(root),'show-ref','--verify','refs/heads/unheld-finished'],env=env,capture_output=True).returncode!=0,'unheld terminal branch deleted with expected-tip guard')
    verify(outcome(result,'unheld-open')['reason']=='open_pr','unheld open PR branch retained')
    verify(not outcome(result,'unheld-advanced')['removed'] and git('rev-parse','unheld-advanced')==advanced_head,'unpublished branch commits retained')
    verify(git('rev-parse','artifact-merged')==merged_row['headRefOid'],'held branch remains intact')

    orphan=worktree('orphan-reg');orphan_moved=tmp/'preserved-orphan';orphan.rename(orphan_moved)
    result=artifacts(extra={'FINISHED_TEST_CWD':str(orphan_moved)})
    verify(outcome(result,orphan)['reason']=='live_process','live manually moved checkout protects its old registration')
    result=artifacts()
    verify(outcome(result,orphan)['removed'] and orphan_moved.exists(),'definite missing-path registration uses git worktree remove, never deletes moved source')
    staged=worktree('orphan-staged');(staged/'README').write_text('staged unpublished text');git('add','README',cwd=staged);staged_moved=tmp/'preserved-staged';staged.rename(staged_moved)
    result=artifacts()
    verify(outcome(result,staged)['reason']=='orphan_staged_changes','orphan registration retains its uncommitted index')
    locked=worktree('orphan-locked');git('worktree','lock',str(locked));locked.rename(tmp/'preserved-locked')
    result=artifacts()
    verify(outcome(result,locked)['reason']=='locked','orphan registration lock always wins')
    checkout=root/'.claude/worktrees/orphan-checkout';checkout.mkdir(parents=True);(checkout/'.git').write_text('gitdir: '+str(root/'.git/worktrees/missing-registration'))
    (checkout/'unpublished').write_text('only copy')
    result=artifacts()
    verify(outcome(result,checkout)['reason']=='orphan_checkout_work_state_unverifiable' and (checkout/'unpublished').read_text()=='only copy','class5 is reported and retained when dirty/unpushed proof is unavailable')

    dead=subprocess.Popen([sys.executable,'-c','pass']);dead.wait();dead_pid=dead.pid
    def scratch(name,number=merged_row['number'],pid=dead_pid):
        path=scratch_root/name;path.mkdir(mode=0o700)
        (path/'nested').mkdir();(path/'nested/data').write_text('synthetic stale scratch')
        (path/'.claude-workspace-artifact.json').write_text(json.dumps(dict(schema_version='1.0',owner_repo='fixture/repo',pr_number=number,owner_pid=pid)))
        for entry in path.rglob('*'):os.utime(entry,(now-8*86400,now-8*86400),follow_symlinks=False)
        os.utime(path,(now-8*86400,now-8*86400));return path
    finished_scratch=scratch('finished')
    live_owner=scratch('live-owner',pid=os.getpid())
    live_cwd=scratch('live-cwd')
    open_scratch=scratch('open-pr',number=open_row['number'])
    protected_scratch=scratch('dotenv');(protected_scratch/'.env').write_text('synthetic protected file');os.utime(protected_scratch,(now-8*86400,now-8*86400))
    symlink_scratch=scratch('symlink');outside=tmp/'outside';outside.write_text('must survive');(symlink_scratch/'link').symlink_to(outside);os.utime(symlink_scratch,(now-8*86400,now-8*86400))
    fresh=scratch('recent-content');(fresh/'nested/data').write_text('recent owner work')
    result=artifacts(extra={'FINISHED_TEST_CWD':str(live_cwd/'nested')})
    verify(not finished_scratch.exists() and outcome(result,finished_scratch)['removed'],'old terminal scratch with dead owner and complete empty census is removed without recursion force')
    verify(outcome(result,finished_scratch)['logical_bytes_reclaimed']>0,'scratch logical byte count follows successful unlinks')
    verify(outcome(result,live_owner)['reason']=='live_owner_process','live owning PID retains scratch')
    verify(outcome(result,live_cwd)['reason']=='live_process','live process cwd retains scratch')
    verify(outcome(result,open_scratch)['reason']=='open_pr','open owner PR retains scratch')
    verify(outcome(result,protected_scratch)['reason']=='protected_workspace_files' and (protected_scratch/'.env').exists(),'dotenv is never touched')
    verify(not outcome(result,symlink_scratch)['removed'] and outside.read_text()=='must survive','symlink-containing scratch retained without touching target')
    verify(outcome(result,fresh)['reason']=='scratch_recent_contents','recent file edits override old directory age')
    unknown=scratch('unknown-process')
    result=artifacts(extra={'FINISHED_TEST_LSOF_FAIL':'1'})
    verify(outcome(result,unknown)['reason']=='process_check_unknown' and unknown.exists(),'incomplete process census fails closed')
    result=artifacts(extra={'FINISHED_TEST_DESKTOP':'1'})
    verify(outcome(result,unknown)['reason']=='desktop_session_liveness_unknown' and unknown.exists(),'unbound desktop sessions retain scratch')

    # The public registration mode makes nested native scratch attributable;
    # it requires an explicit durable owning ancestor, not a guessed dead PID.
    nested=scratch_root/'container/session/scratchpad';nested.mkdir(parents=True,mode=0o700)
    runner=source/'.claude/scripts/workspace-sweep.sh'
    register_args=['bash',str(runner),'--repo-dir',str(root),'--register-scratch',str(nested),'--pr',str(merged_row['number'])]
    parent=subprocess.run([sys.executable,'-c','import os,subprocess,sys;sys.exit(subprocess.run(sys.argv[1:]+["--owner-pid",str(os.getpid())]).returncode)',*register_args],cwd=root,env=env,text=True,capture_output=True,timeout=15)
    verify(parent.returncode==0,(parent.stdout,parent.stderr))
    marker=nested/'.claude-workspace-artifact.json'
    verify(marker.exists() and marker.stat().st_mode&0o777==0o600,'scratch registration publishes a private ownership record')
    registry=Path(env['HOME'])/'.claude/workspace-sweep/scratch-artifacts.json'
    verify(str(nested.resolve()) in json.loads(registry.read_text())['repositories']['github.com/fixture/repo'],'nested scratch is indexed for cadence discovery')
    for entry in nested.rglob('*'):os.utime(entry,(now-8*86400,now-8*86400))
    os.utime(nested,(now-8*86400,now-8*86400))
    result=artifacts()
    verify(not nested.exists() and outcome(result,nested)['removed'],'registered nested scratch is reaped after its actual owning process exits')
    verify(str(nested.resolve()) not in json.loads(registry.read_text())['repositories']['github.com/fixture/repo'],'successful cleanup prunes only the retired discovery entry')
    outside_dir=tmp/'not-a-scratch-root';outside_dir.mkdir()
    result=subprocess.run(['bash',str(runner),'--repo-dir',str(root),'--register-scratch',str(outside_dir),'--pr',str(merged_row['number']),'--owner-pid',str(os.getpid())],cwd=root,env=env,text=True,capture_output=True,timeout=15)
    verify(result.returncode!=0 and not (outside_dir/'.claude-workspace-artifact.json').exists(),'registration cannot turn an arbitrary directory into sweepable scratch')
    result=subprocess.run([*register_args,'--owner-pid',str(os.getpid()),'--report'],cwd=root,env=env,text=True,capture_output=True,timeout=15)
    verify(result.returncode!=0,'report cannot silently accept a registration request')

    # Discovery state cannot expand the cleanup namespace, even with otherwise
    # plausible terminal ownership metadata.
    outside_scope=tmp/'valuable-outside-scratch';outside_scope.mkdir(mode=0o700)
    (outside_scope/'data').write_text('must survive an injected index entry')
    (outside_scope/'.claude-workspace-artifact.json').write_text(json.dumps(dict(schema_version='1.0',owner_repo='fixture/repo',pr_number=merged_row['number'],owner_pid=dead_pid)))
    for entry in outside_scope.rglob('*'):os.utime(entry,(now-8*86400,now-8*86400))
    os.utime(outside_scope,(now-8*86400,now-8*86400))
    indexed=json.loads(registry.read_text());indexed['repositories']['github.com/fixture/repo']=[str(outside_scope.resolve())]
    registry.write_text(json.dumps(indexed));registry.chmod(0o600);registry_before=registry.read_bytes()
    result=artifacts()
    verify(outcome(result,outside_scope)['reason']=='scratch_outside_roots' and (outside_scope/'data').exists(),'injected index entry cannot authorize cleanup outside scratch roots')
    verify(registry.read_bytes()==registry_before,'uncertain outside-root entry remains available for inspection')
    indexed['repositories']['github.com/fixture/repo']=[];registry.write_text(json.dumps(indexed));registry.chmod(0o600)

    # A refused worktree removal lists the raced path without force.
    gitshim=bin_dir/'git';text=gitshim.read_text();text=text.replace("if 'worktree' in a and 'remove' in a and os.environ.get('FINISHED_TEST_REMOVE_RACE'):","if 'worktree' in a and 'remove' in a and os.environ.get('FINISHED_TEST_REMOVE_RACE'):\n Path(a[-1]).mkdir(parents=True,exist_ok=True)")
    gitshim.write_text(text)
    refused=worktree('orphan-refused');refused.rename(tmp/'preserved-refused')
    result=artifacts(extra={'FINISHED_TEST_REMOVE_RACE':'1'})
    verify(outcome(result,refused)['reason']=='orphan_remove_refused' and '.DS_Store' in outcome(result,refused).get('remaining_entries',''),'orphan removal refusal lists the path without forced deletion')
    verify((refused/'.DS_Store').exists(),'the raced directory remains')
    verify(result['removed'] is None and result['known_removed']>=0,'uncertain mutation reports unknown total plus a known lower bound, never fabricated zero')

    # Exercise the real inventory/deletion boundary while creating a protected
    # file between the two inventories. Only the disposable fixture is changed.
    module_spec=importlib.util.spec_from_file_location('artifacts_fixture',helper)
    artifacts_module=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(artifacts_module)
    raced=scratch('env-race');real_inventory=artifacts_module.Artifacts.inventory;calls=[0]
    def inventory(path):
        calls[0]+=1
        if calls[0]==2:(path/'.env').write_text('arrived before deletion')
        return real_inventory(path)
    # Keep network/proc reads at the same fake boundary inside this process.
    saved=dict(os.environ);os.environ.update(env)
    try:
        instance=artifacts_module.Artifacts(root,Path(env['HOME']),now,True)
        instance.inventory=inventory
        row={'removed':False,'logical_bytes_reclaimed':0}
        try:instance.scratch(raced,row)
        except artifacts_module.finished.Skip as exc:reason=str(exc)
        else:raise AssertionError('dotenv race unexpectedly permitted cleanup')
        verify(reason=='protected_workspace_files' and (raced/'.env').exists() and (raced/'nested/data').exists(),'pre-delete dotenv race retains all scratch data')
    finally:
        os.environ.clear();os.environ.update(saved)
    saved=dict(os.environ);os.environ.update(env)
    try:
        first=artifacts_module.Artifacts(root,Path(env['HOME']),now,False,limit=1).scan()
        second=artifacts_module.Artifacts(root,Path(env['HOME']),now,False,limit=1,cursor=first['next_cursor']).scan()
        verify(first['truncated'] and first['next_cursor']!=0,'bounded artifact batch records a continuation cursor')
        verify(first['artifacts'][0]['path']!=second['artifacts'][0]['path'],'continuation advances beyond retained first entries')
    finally:
        os.environ.clear();os.environ.update(saved)
    commands=[json.loads(line) for line in Path(env['FINISHED_TEST_LOG']).read_text().splitlines()]
    verify(not any('clean' in c or '--force' in c or '-f' in c or '-D' in c for c in commands),'artifact code never git-cleans or forces worktree/ref deletion')
    print(str(checks)+' artifact safety checks passed; private files/Git only')
'''
exec(compile(bootstrap+cases,'workspace-artifacts-fixtures','exec'))
PY
