#!/bin/bash
# catalog: tests — Validate daily workspace LaunchAgent dry-run, install rollback, escaping and retained-state uninstall offline
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json,os,plistlib,shutil,subprocess,sys,tempfile
from pathlib import Path
source=Path(sys.argv[1]);checks=0

def verify(ok, message):
    global checks
    assert ok,message
    checks+=1

with tempfile.TemporaryDirectory(prefix='workspace-install-test-') as directory:
    tmp=Path(directory);home=tmp/'home & <safe>';home.mkdir();bin=tmp/'bin';bin.mkdir()
    label='com.user.claude-workspace-sweep'
    env=dict(os.environ,HOME=str(home),PATH=str(bin)+os.pathsep+os.environ['PATH'],LAUNCH_STATE=str(tmp/'loaded'),LAUNCH_LOG=str(tmp/'launch.log'),LAUNCH_FAIL=str(tmp/'fail'))
    (bin/'uname').write_text('#!/bin/bash\necho Darwin\n')
    (bin/'plutil').write_text('#!/bin/bash\nexit 0\n')
    (bin/'launchctl').write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:];state=Path(os.environ['LAUNCH_STATE']);fail=Path(os.environ['LAUNCH_FAIL'])
with open(os.environ['LAUNCH_LOG'],'a') as f:f.write(json.dumps(a)+'\\n')
if fail.exists() and fail.read_text().split(',')[0]==a[0]:
 sequence=fail.read_text().split(',')[1:]
 if sequence:fail.write_text(','.join(sequence))
 else:fail.unlink()
 sys.exit(1)
if a[0]=='bootout':state.unlink(missing_ok=True)
elif a[0]=='bootstrap':
 if fail.exists() and fail.read_text()=='fail once':fail.unlink();sys.exit(1)
 state.write_text('loaded')
elif a[0]=='list':sys.exit(0 if state.exists() else 1)
''')
    for name in ('gh','jq','lsof'):
        if not shutil.which(name): (bin/name).write_text('#!/bin/bash\nexit 0\n')
    for path in bin.iterdir():path.chmod(0o755)
    script=source/'.claude/scripts/install-workspace-sweep.sh'
    def run(*args, uninstall=False):
        selected=source/'.claude/scripts/uninstall-workspace-sweep.sh' if uninstall else script
        return subprocess.run(['bash',str(selected),*args],env=env,text=True,capture_output=True,timeout=30)
    before=list(home.rglob('*'));result=run('--dry-run','--hour','7')
    verify(result.returncode==0,(result.stdout,result.stderr))
    verify(list(home.rglob('*'))==before and not (tmp/'launch.log').exists(),'dry run creates no files/directories and never calls launchctl')
    config=plistlib.loads(result.stdout.split('# Manual command:',1)[0].encode())
    verify(config['StartCalendarInterval']=={'Hour':7,'Minute':0},'dry run has requested daily calendar')
    verify(config['ProgramArguments'][-3:]==['--trigger','daily','--configured'],'dry run uses configured daily runner')
    verify(config['StandardOutPath'].startswith(str(home)),'XML round-trip preserves metacharacters in home path')
    verify(run('--hour','24','--dry-run').returncode!=0 and not (tmp/'launch.log').exists(),'invalid hour fails without side effects')
    result=run('--hour','7');verify(result.returncode==0,(result.stdout,result.stderr))
    target=home/'Library/LaunchAgents'/ (label+'.plist');prior=target.read_bytes()
    calls=[json.loads(s)[0] for s in (tmp/'launch.log').read_text().splitlines()]
    verify(calls==['bootout','bootstrap','enable','kickstart','list'],'normal installer follows launchd lifecycle')
    (tmp/'fail').write_text('fail once');result=run('--hour','8')
    verify(result.returncode!=0 and target.read_bytes()==prior and (tmp/'loaded').exists(),'failed bootstrap restores previous plist and job')
    verify(target.with_suffix('.plist.bak').read_bytes()==prior,'previous plist backup retained')
    for stage in ('enable','kickstart','list'):
        (tmp/'fail').write_text(stage);result=run('--hour','8')
        verify(result.returncode!=0 and target.read_bytes()==prior and (tmp/'loaded').exists(),stage+' failure restores previous plist and job')
        calls=[json.loads(s)[0] for s in (tmp/'launch.log').read_text().splitlines()]
        verify(calls[-3:]==['bootout','list','bootstrap'],stage+' rollback first verifies removal of the new job then restores the old job')
    target.unlink();(tmp/'loaded').unlink(missing_ok=True)
    (tmp/'fail').write_text('kickstart');result=run('--hour','8')
    verify(result.returncode!=0 and not target.exists() and not (tmp/'loaded').exists(),'failed first install removes new job and plist')
    target.write_bytes(prior);(tmp/'loaded').write_text('loaded')
    for sequence in ('kickstart,bootout','kickstart,bootstrap'):
        (tmp/'fail').write_text(sequence);result=run('--hour','8')
        verify(result.returncode!=0 and 'rollback failed' in result.stderr,'rollback failure is explicit for '+sequence)
        if sequence.endswith('bootout'):
            verify((tmp/'loaded').exists() and target.exists() and target.with_suffix('.plist.bak').read_bytes()==prior,'unload failure retains definition and backup for recovery')
        else:
            verify(not (tmp/'loaded').exists() and target.read_bytes()==prior,'restore-bootstrap failure retains previous definition for recovery')
        target.write_bytes(prior);(tmp/'loaded').write_text('loaded')
    config=plistlib.loads(prior);config['ProgramArguments'][1]='/different/runner'
    target.write_bytes(plistlib.dumps(config));result=run('--dry-run')
    verify(result.returncode!=0 and 'force' in result.stderr,'different installed runner requires force')
    result=run('--force','--dry-run');verify(result.returncode==0,'force dry run validates without replacing existing job')
    retained=home/'.claude/workspace-sweep';retained.mkdir();(retained/'keep').write_text('state')
    result=run(uninstall=True)
    verify(result.returncode==0 and not target.exists() and (retained/'keep').exists(),'uninstall removes job and retains sweep state')
    print(str(checks)+' installer checks passed')
PY
