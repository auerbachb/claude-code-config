#!/usr/bin/env bash
# catalog: tests — Private-home integration checks for bounded config-sync setup, pending recovery, and ownership
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 - "$repo" "$BASH" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile, time
repo=pathlib.Path(sys.argv[1]); bash=sys.argv[2]; checks=0

def check(ok, message):
    global checks
    assert ok, message
    checks+=1
    print('ok', checks, message, flush=True)

def run(argv, **kw):
    return subprocess.run([str(x) for x in argv], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=40, **kw)

def write(p, text):
    p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text); p.chmod(0o755)

with tempfile.TemporaryDirectory(prefix='sync-tail-test-') as td:
    base=pathlib.Path(td)
    def fixture(name, old=False):
        p=base/name; tree=p/'tree'; home=p/'home'; scripts=tree/'.claude/scripts'; hooks=tree/'.claude/hooks'
        scripts.mkdir(parents=True); hooks.mkdir(parents=True); (home/'.claude/logs').mkdir(parents=True)
        for rel in ['scripts/claude-config-sync.sh','scripts/config-sync-tail.sh','scripts/state-lock.sh', 'scripts/repo-root.sh','scripts/lib/bounded-run.sh','scripts/lib/config-sync-pending.sh','hooks/session-start-sync.sh']:
            dest=tree/'.claude'/rel; dest.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(repo/'.claude'/rel,dest)
        for x in ['publish-skill-symlinks.sh','publish-agent-symlinks.sh']:
            write(scripts/x,'#!/bin/bash\nexit 0\n')
        write(hooks/'register-hooks.py', 'import os,time\nfrom pathlib import Path\np=Path(os.environ["HOME"])/".claude"\n(p/"hooks-started").write_text("yes")\n(p/"legacy-hooks-root").write_text(os.environ.get("MANAGED_LEGACY_HOOKS_DIR",""))\nif (p/"stall-hooks").exists(): time.sleep(12)\n(p/"hooks-done").write_text("yes")\n')
        write(scripts/'repair-trust-all.sh','#!/bin/bash\ntouch "$HOME/.claude/trust-started"\nif [[ -f "$HOME/.claude/stall-trust" ]]; then sleep 12; fi\ntouch "$HOME/.claude/trust-done"\n')
        write(tree/'.claude/skills/alpha/SKILL.md','# fixture skill\n')
        for cmd in [['git','init','-q',tree],['git','-C',tree,'symbolic-ref','HEAD','refs/heads/main'],['git','-C',tree,'add','.'],['git','-C',tree,'-c','user.name=test','-c','user.email=test@example.invalid','commit','-qm','fixture']]:
            r=run(cmd); assert r.returncode==0,r.stderr
        # Real local origin and worktree; no provider, network, Keychain or owner settings.
        r=run(['git','clone','-q',tree,p/'clone']); assert r.returncode==0,r.stderr
        r=run(['git','-C',p/'clone','worktree','add','--detach',home/'.claude/skills-worktree','main']); assert r.returncode==0,r.stderr
        if old:
            for rel in ['scripts/claude-config-sync.sh','hooks/session-start-sync.sh']:
                text=run(['git','-C',repo,'show','33b130074f6007d281ba6d8d50410cb5de37ea59:.claude/'+rel]); assert text.returncode==0
                write(tree/'.claude'/rel,text.stdout)
        env=os.environ.copy()
        for k in list(env):
            if k.startswith(('CLAUDE_STATE_LOCK','CLAUDE_CONFIG_SYNC','BOUNDED_')): env.pop(k)
        env.update(HOME=str(home),CLAUDE_CONFIG_SYNC_TAIL_BOUND='3',CLAUDE_CONFIG_SYNC_HOOK_REGISTER_BOUND='3',CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_SECS='90',CLAUDE_CONFIG_SYNC_HOOK_TIMEOUT_RAISE_OK='1')
        return p,tree,home,env
    def invoke(f, mode='scheduled'):
        p,tree,home,env=f; start=time.monotonic()
        script=tree/'.claude'/('scripts/claude-config-sync.sh' if mode=='scheduled' else 'hooks/session-start-sync.sh')
        r=run([bash,script]+(['--json'] if mode=='scheduled' else []),env=env,cwd=p,input='{"source":"startup"}')
        assert r.returncode==0,(mode,r.returncode,r.stderr[-500:],r.stdout[-2000:])
        check(True,mode+' entrypoint returns a report')
        return json.loads(r.stdout),time.monotonic()-start
    def state(f): return json.loads((f[2]/'.claude/logs/claude-config-sync-state.json').read_text())
    for mode in ['scheduled','hook']:
        f=fixture(mode+'-control'); out,elapsed=invoke(f,mode)
        check((f[2]/'.claude/hooks-done').exists(),mode+' ample control runs registration')
        check(state(f)['pending_setup']['hooks'] is False,mode+' confirmed registration clears pending')
        check(pathlib.Path((f[2]/'.claude/legacy-hooks-root').read_text()).resolve()==(f[0]/'clone/.claude/hooks').resolve(),mode+' forwards the resolved legacy hooks root to the actual registrar')
        if mode=='scheduled':
            check(out['outcome']=='ok' and state(f)['pending_setup']['trust'] is False,'scheduled ample control completes trust')
        for operation in (['hooks','trust'] if mode=='scheduled' else ['hooks']):
            f=fixture(mode+'-'+operation); (f[2]/('.claude/stall-'+operation)).touch()
            if mode=='hook':
                marker=f[2]/'.claude/sync-restart-recommended.json'
                marker.write_text(json.dumps({'restart_recommended':{'reason':'fixture','categories':['skills'],'head_sha':'0'*40,'at':'2026-11-01T00:00:00Z'}}))
            out,elapsed=invoke(f,mode)
            if mode=='hook': check(marker.exists() and 'restart_recommended' in json.loads(marker.read_text()),'partial hook registration preserves the restart signal')
            check(elapsed<11,mode+' stalled '+operation+' is bounded')
            check((f[2]/('.claude/'+operation+'-started')).exists() and not (f[2]/('.claude/'+operation+'-done')).exists(),mode+' stalled child starts but cannot complete')
            check(state(f)['pending_setup'][operation] is True,mode+' interrupted mutation remains pending')
            check('exceeded its 3s bound' in json.dumps(out),mode+' actual elapsed timeout is reported honestly')
            (f[2]/('.claude/stall-'+operation)).unlink(); out,_=invoke(f,mode)
            check(state(f)['pending_setup'][operation] is False,mode+' unchanged HEAD next tick retries pending operation')
            check((f[2]/('.claude/'+operation+'-done')).exists(),mode+' retry actually completes mutation')
    # Old published actual entrypoints: the identical slow child completes,
    # exceeding its intended three-second call bound (outer subprocess timeout remains finite).
    for mode in ['scheduled','hook']:
        f=fixture('old-'+mode,old=True); (f[2]/'.claude/stall-hooks').touch()
        _,elapsed=invoke(f,mode)
        check(elapsed>=12 and (f[2]/'.claude/hooks-done').exists(),'published old '+mode+' reproduces unbounded registration')
    # Readonly verification can stall too: the full walk, including readlink,
    # must be inside the bounded child rather than its parent.
    for old in [False,True]:
        f=fixture('verify-'+str(old),old=old); p,tree,home,env=f
        (home/'.claude/CLAUDE.md').symlink_to(home/'missing-target')
        shim=p/'bin'; shim.mkdir(); real=shutil.which('readlink'); assert real
        write(shim/'readlink','#!/bin/bash\ncase "$1" in */.claude/CLAUDE.md) n=$(cat "$HOME/readlink-count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$HOME/readlink-count"; if [[ "$n" == 3 ]]; then sleep 12; fi ;; esac\nexec '+real+' "$@"\n')
        env['PATH']=str(shim)+os.pathsep+env['PATH']
        out,elapsed=invoke(f)
        if old:
            check(elapsed>=12,'published old verification overruns the three-second ceiling')
        else:
            check(elapsed<11 and out['outcome']=='incomplete','entire readonly verification walk is bounded')
            check((home/'readlink-count').read_text().strip()=='3','stall shim reaches verification after the two parent snapshots')
            check('verification incomplete: exceeded its 3s bound' in json.dumps(out),'verification timeout is recorded')
            check(state(f)['pending_setup']=={'hooks':False,'trust':False},'verification failure does not invent pending mutations')
    # Exercise actual scheduling functions at their prelaunch boundaries without
    # corrupting the earlier git region's clock or invoking real setup helpers.
    import re
    source=(repo/'.claude/scripts/claude-config-sync.sh').read_text()
    funcs='\n'.join(re.search(r'^'+name+r'\(\).*?^}',source,re.M|re.S).group() for name in ['_tail_remaining','run_tail'])
    f=fixture('decline'); p,tree,home,env=f
    setup='source "$1/state-lock.sh"; source "$1/lib/bounded-run.sh"; STATE_FILE="$2"; state_lock_acquire "$STATE_FILE" 1; SCRIPT_DIR="$1"; SKILLS_WT="$HOME/.claude/skills-worktree"; ROOT_REPO_HINT=""; GIT_BOUND_AVAILABLE=1; CAPTURE=$(mktemp "$HOME/out.XXXXXX"); CAPTURE_ERR=$(mktemp "$HOME/err.XXXXXX"); _tail_region_budget=112; TAIL_BOUND_SECS=1; '
    for label,assignment in [('clock','_git_region_t0=unknown'),('elapsed','_git_region_t0=1'),('library','_git_region_t0=$(date -u +%s); GIT_BOUND_AVAILABLE=0'),('capture','_git_region_t0=$(date -u +%s); CAPTURE=""')]:
        sf=home/'.claude/logs/claude-config-sync-state.json'
        r=run([bash,'-c',funcs+'\n'+setup+assignment+'; rc=0; run_tail hooks || rc=$?; printf "%s %s %s" "$rc" "$TAIL_DECLINED" "$TAIL_STDERR"', '_',tree/'.claude/scripts',sf],env=env)
        check(r.returncode==0 and r.stdout.startswith('124 1 declined:'),label+' prelaunch decline is classified honestly')
        check(not (home/'.claude/hooks-started').exists(),label+' prelaunch decline never starts the mutator')
    hook_source=(repo/'.claude/hooks/session-start-sync.sh').read_text()
    hook_funcs='\n'.join(re.search(r'^'+name+r'\(\).*?^}',hook_source,re.M|re.S).group() for name in ['_budget_remaining','_run_hook_bounded','_bound_trip_reason'])
    hook_setup='source "$1/lib/bounded-run.sh"; _HOOK_TIMEOUT_SECS=30; _HOOK_GIT_RESERVE_SECS=9; _HOOK_MIN_BOUND_SECS=3; _bound_available=1; CAPTURE=$(mktemp "$HOME/out.XXXXXX"); CAPTURE_ERR=$(mktemp "$HOME/err.XXXXXX"); '
    for label,assignment,reason in [('unknown-clock','_hook_t0=unknown','declined:'),('backward-clock','_hook_t0=999999999999','declined:'),('library','_hook_t0=$(date -u +%s); _bound_available=0','declined:'),('postlaunch-clock','_hook_t0=$(date -u +%s); run_bounded() { BOUNDED_TIMED_OUT=1; BOUNDED_CLOCK_UNREADABLE=1; return 124; }','aborted: clock'),('postlaunch-capture','_hook_t0=$(date -u +%s); run_bounded() { rm -f "$CAPTURE_ERR"; mkdir "$CAPTURE_ERR"; return 0; }','output capture unreadable')]:
        r=run([bash,'-c',hook_funcs+'\n'+hook_setup+assignment+'; rc=0; _run_hook_bounded --reserve 8 --strict-clock 1 touch "$HOME/should-not-run" || rc=$?; if [[ "$BOUNDED_TIMED_OUT" == 1 ]]; then reason=$(_bound_trip_reason); else reason=$_bounded_out; fi; printf "%s %s" "$rc" "$reason"', '_',tree/'.claude/scripts'],env=env)
        check(r.returncode==0 and r.stdout.startswith('124 ') and reason in r.stdout,'hook '+label+' is classified honestly: '+r.stdout)
        check(not (home/'should-not-run').exists(),'hook '+label+' does not run an unbounded mutator')
    f=fixture('malformed-entry'); p,tree,home,env=f
    sf=home/'.claude/logs/claude-config-sync-state.json'; sf.write_text('{malformed')
    out,_=invoke(f)
    check(sf.read_text()=='{malformed' and out['outcome']=='incomplete','scheduled tail retains malformed state rather than replacing it with success')
    check(not (home/'.claude/hooks-started').exists() and not (home/'.claude/trust-started').exists(),'unpersisted pending intent declines both mutators')
    # Direct pending-state protocol: real state lock and actual child entrypoint.
    f=fixture('protocol'); p,tree,home,env=f; sf=home/'.claude/logs/claude-config-sync-state.json'
    sf.write_text('{"custom":{"keep":7},"pending_setup":{"future":"keep"}}')
    common='source "$1/state-lock.sh"; source "$1/lib/config-sync-pending.sh"; state_lock_acquire "$2" 1; '
    r=run([bash,'-c',common+'config_sync_pending_set "$2" hooks true; config_sync_pending_set "$2" hooks false', '_',tree/'.claude/scripts',sf],env=env)
    check(r.returncode==0 and state(f)=={'custom':{'keep':7},'pending_setup':{'future':'keep','hooks':False}},'pending updates preserve unknown state and false boolean')
    for invalid in ['[]','{bad','{} {}','{"pending_setup":{"hooks":"yes"}}']:
        sf.write_text(invalid)
        r=run([bash,'-c',common+'config_sync_pending_set "$2" hooks true', '_',tree/'.claude/scripts',sf],env=env)
        check(r.returncode==4 and sf.read_text()==invalid,'malformed pending state is retained without mutation')
    sf.write_text('{}')
    r=run([bash,'-c',common+'printf "token=replaced\\n" > "$2.lock/owner"; config_sync_pending_set "$2" hooks false', '_',tree/'.claude/scripts',sf],env=env)
    check(r.returncode==6 and sf.read_text()=='{}','lost ownership refuses completion state')
    shutil.rmtree(str(sf)+'.lock',ignore_errors=True)
    r=run([bash,tree/'.claude/scripts/config-sync-tail.sh','hooks','--skills-worktree',home/'.claude/skills-worktree','--state-file',sf],env=env)
    check(r.returncode==6 and not (home/'.claude/hooks-started').exists(),'bounded child refuses mutator without inherited verified lock')
print('PASS:',checks,'checks')
PY
