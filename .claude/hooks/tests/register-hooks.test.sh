#!/usr/bin/env bash
# catalog: tests — Verify multi-event hook installation, idempotency, migration, and owned stale-event cleanup
set -euo pipefail
ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Exercise the actual installer CLI. Every settings write stays in a temp HOME;
# neither installed hook execution nor a real user configuration is involved.
python3 - "$ROOT" "$TMP" <<'PY'
import json,os,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]);base=pathlib.Path(sys.argv[2])
installer=root/'.claude/hooks/register-hooks.py'
worktree=base/'skills-worktree';hooks=worktree/'.claude/hooks';hooks.mkdir(parents=True)
legacy=base/'legacy-hooks';legacy.mkdir()
for name in ('shared.sh','single.sh'):
    (hooks/name).write_text('#!/bin/sh\nexit 0\n')
(legacy/'shared.sh').write_text('#!/bin/sh\nexit 0\n')
home=base/'synthetic-home';settings=home/'.claude/settings.json';settings.parent.mkdir(parents=True)
env=dict(os.environ,HOME=str(home),MANAGED_LEGACY_HOOKS_DIR=str(legacy))

def group(command,timeout=5):return {'hooks':[{'type':'command','command':command,'timeout':timeout}]}
def write(path,value):path.write_text(json.dumps(value)+'\n')
def install(tree=worktree,custom_env=env):
    result=subprocess.run([sys.executable,str(installer),str(tree)],env=custom_env,capture_output=True,text=True,check=True,timeout=10)
    return result.stderr

def load():return json.loads(settings.read_text())
def commands(value,event):
    return [hook['command'] for entry in value['hooks'].get(event,[]) for hook in entry.get('hooks',[])]
def template(single_event='Stop'):
    return {'hooks':{'TaskCreated':[group('/path/to/claude-code-config/.claude/hooks/shared.sh')],
                     'TaskCompleted':[group('/path/to/claude-code-config/.claude/hooks/shared.sh')],
                     single_event:[group('/path/to/claude-code-config/.claude/hooks/single.sh')]}}
manifest=worktree/'global-settings.json';write(manifest,template())
custom=group(str(base/'user-hooks/custom.sh'),31)
write(settings,{'hooks':{'PostToolUse':[custom]},'userSetting':'preserve'})
# First install must retain BOTH canonical events of the shared script.
install();value=load()
for event in ('TaskCreated','TaskCompleted'):
    assert commands(value,event)==[str(hooks/'shared.sh')],event
assert commands(value,'Stop')==[str(hooks/'single.sh')]
assert value['hooks']['PostToolUse']==[custom] and value['userSetting']=='preserve'
# Repeated installs are real no-ops, with no duplicates or atomic rewrite.
before=settings.read_bytes();inode=settings.stat().st_ino
assert install()==''
assert settings.read_bytes()==before and settings.stat().st_ino==inode

# Upgrade: repair a valid legacy path while preserving args/timeout, retain the
# second valid shared-script event, and prune a third managed wrong event.
value['hooks']['TaskCreated'][0]['hooks'][0].update(command=str(legacy/'shared.sh')+' --check',timeout=47)
user_shared=group(str(base/'user-hooks/shared.sh'),39)
placeholder=group('/path/to/claude-code-config/.claude/hooks/shared.sh',13)
wrong=group(str(hooks/'shared.sh'))
wrong['hooks'].append(dict(custom['hooks'][0]))
value['hooks']['PreToolUse']=[wrong,group(str(legacy/'shared.sh'))]
value['hooks']['PostToolUse'].extend([user_shared,placeholder])
# Decommissioned managed files remain prunable; an unmanaged missing script is
# still a user's hook and must survive.
value['hooks']['PostToolUse'].append(group(str(hooks/'retired.sh')))
write(settings,value);write(manifest,template(single_event='SessionEnd'))
install();updated=load()
created=updated['hooks']['TaskCreated'][0]['hooks'][0]
assert created['command']==str(hooks/'shared.sh')+' --check' and created['timeout']==47
assert commands(updated,'TaskCompleted')==[str(hooks/'shared.sh')]
assert updated['hooks']['PreToolUse']==[custom],updated['hooks']['PreToolUse']
assert updated['hooks']['PostToolUse']==[custom,user_shared,placeholder]
assert 'Stop' not in updated['hooks'] and commands(updated,'SessionEnd')==[str(hooks/'single.sh')]
before=settings.read_bytes();assert install()=='' and settings.read_bytes()==before
print('PASS: shared-script first/repeated install and update preserve both valid events; only owned stale events are pruned')

# Integration proof against this repository's REAL manifest and hook files.
# A direct manifest declaration alone does not establish installed coverage.
actual_home=base/'actual-home';actual_settings=actual_home/'.claude/settings.json'
actual_env=dict(env,HOME=str(actual_home),MANAGED_LEGACY_HOOKS_DIR='')
install(root,actual_env)
installed=json.loads(actual_settings.read_text())
for script,events in (('spend-task-tracker.sh',('TaskCreated','TaskCompleted')),
                      ('spend-session-tracker.sh',('SessionStart','SessionEnd'))):
    for event in events:
        assert commands(installed,event).count(str(root/'.claude/hooks'/script))==1,(script,event)
before=actual_settings.read_bytes();inode=actual_settings.stat().st_ino
assert install(root,actual_env)==''
assert actual_settings.read_bytes()==before and actual_settings.stat().st_ino==inode
print('PASS: actual repository installer retains both task and session tracker events once each and is idempotent')
PY
