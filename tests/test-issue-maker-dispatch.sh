#!/usr/bin/env bash
# Focused contract checks for the incremental /issue-maker dispatcher.
# This verifies module selection and a file-read trace at the caller boundary;
# it does not claim to observe Claude Code's private runtime loader.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DISPATCH="$ROOT/.claude/skills/issue-maker/scripts/dispatch-module.sh"
TRACE="$(mktemp "${TMPDIR:-/tmp}/issue-maker-trace.XXXXXX")"
trap 'rm -f "$TRACE"' EXIT

total=0
fail=0
assert_eq() {
  local expected="$1" actual="$2" name="$3"
  total=$((total + 1))
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok %s\n' "$name"
  else
    printf 'not ok %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

read_path_once() {
  local key="$1" path="$2"
  [[ -n "${loaded[$key]:-}" ]] && return 0
  [[ -r "$path" ]] || return 1
  cat "$path" >/dev/null
  printf '%s\n' "$(cd -- "$(dirname -- "$path")" && pwd -P)/$(basename -- "$path")" >> "$TRACE"
  loaded[$key]=1
}

load_once() {
  # Mirrors the entry-point contract: a phase already read in this context is
  # reused; only the single path returned by the dispatcher is opened.
  local op="$1" phase="$2" module
  module=$("$DISPATCH" "$op" "$phase")
  read_path_once "module:$op:$phase" "$module"
}

load_reference() {
  # A nested reference is opened only when the selected procedure reaches its
  # named trigger; unrelated references stay out of the trace.
  read_path_once "reference:$2" "$2"
}

declare -A loaded=()
load_once session state
load_once create reflect
load_reference tier-inference .claude/skills/issue-maker/references/tier-inference.md
load_reference time-estimates .claude/reference/time-estimates.md
load_once create dedup
load_reference path-resolution .claude/reference/portable-skill-resolution.md
load_reference autofile-dedup .claude/reference/autofile-dedup.md
load_once create file
load_once create postfile
load_once create dedup # Reuse the module already read in this context.
actual=$(cat "$TRACE")
expected=$(cat <<'EXPECTED'
.claude/skills/issue-maker/modules/session-state.md
.claude/skills/issue-maker/modules/create/reflect-and-draft.md
.claude/skills/issue-maker/references/tier-inference.md
.claude/reference/time-estimates.md
.claude/skills/issue-maker/modules/create/dedup.md
.claude/reference/portable-skill-resolution.md
.claude/reference/autofile-dedup.md
.claude/skills/issue-maker/modules/create/file.md
.claude/skills/issue-maker/modules/create/postfile.md
EXPECTED
)
expected=$(printf '%s\n' "$expected" | sed "s#^#$ROOT/#")
assert_eq "$expected" "$actual" 'create trace reads selected phases and required nested references; repeat is reused'

: > "$TRACE"
loaded=()
load_once session state
load_once update edit
actual=$(cat "$TRACE")
expected=$(cat <<'EXPECTED'
.claude/skills/issue-maker/modules/session-state.md
.claude/skills/issue-maker/modules/update.md
EXPECTED
)
expected=$(printf '%s\n' "$expected" | sed "s#^#$ROOT/#")
assert_eq "$expected" "$actual" 'update trace does not read create, batch, retract, export, or references'

: > "$TRACE"
loaded=()
load_once session state
load_once retract close
actual=$(cat "$TRACE")
expected=$(cat <<'EXPECTED'
.claude/skills/issue-maker/modules/session-state.md
.claude/skills/issue-maker/modules/retract.md
EXPECTED
)
expected=$(printf '%s\n' "$expected" | sed "s#^#$ROOT/#")
assert_eq "$expected" "$actual" 'retract trace reads only session and retract modules'

: > "$TRACE"
loaded=()
load_once session state
load_once create reflect
load_once create increment-draft
load_reference tier-inference .claude/skills/issue-maker/references/tier-inference.md
load_reference time-estimates .claude/reference/time-estimates.md
load_once batch chain
load_once create dedup
load_reference path-resolution .claude/reference/portable-skill-resolution.md
load_reference autofile-dedup .claude/reference/autofile-dedup.md
load_once create crossrefs
load_once create file
load_once create postfile
actual=$(cat "$TRACE")
expected=$(cat <<'EXPECTED'
.claude/skills/issue-maker/modules/session-state.md
.claude/skills/issue-maker/modules/create/reflect-and-draft.md
.claude/skills/issue-maker/modules/create/increment-draft.md
.claude/skills/issue-maker/references/tier-inference.md
.claude/reference/time-estimates.md
.claude/skills/issue-maker/modules/batch.md
.claude/skills/issue-maker/modules/create/dedup.md
.claude/reference/portable-skill-resolution.md
.claude/reference/autofile-dedup.md
.claude/skills/issue-maker/modules/create/crossrefs.md
.claude/skills/issue-maker/modules/create/file.md
.claude/skills/issue-maker/modules/create/postfile.md
EXPECTED
)
expected=$(printf '%s\n' "$expected" | sed "s#^#$ROOT/#")
assert_eq "$expected" "$actual" 'batch trace loads increment rules, chain steps, and required nested references'

: > "$TRACE"
loaded=()
load_once export prompt
# Bounded literal sources are emitted by a tool, rather than loaded as workflows.
reflect="$ROOT/.claude/skills/issue-maker/modules/create/reflect-and-draft.md"
handoff="$ROOT/.claude/skills/issue-maker/modules/handoff.md"
body_excerpt=$(awk '/^## Step 5: Canonical issue body/ {on=1} on {print} on && /^```$/ {closed=1; exit} END {if (!on || !closed) exit 1}' "$reflect")
[[ "$body_excerpt" == *'## Background'* && "$body_excerpt" == *'## Estimate'* ]]
printf '%s#body-template\n' "$reflect" >> "$TRACE"
handoff_excerpt=$(awk '/^\*\*Model:\*\*/ {on=1} on {print} on && /^```$/ {closed=1; exit} END {if (!on || !closed) exit 1}' "$handoff")
[[ "$handoff_excerpt" == *'## Constraints'* && "$handoff_excerpt" == *'Merging is automatic and yours to do'* ]]
printf '%s#handoff-template\n' "$handoff" >> "$TRACE"
load_reference chip-launching .claude/reference/chip-launching.md
actual=$(cat "$TRACE")
expected=$(cat <<'EXPECTED'
.claude/skills/issue-maker/modules/portable-prompt.md
.claude/skills/issue-maker/modules/create/reflect-and-draft.md#body-template
.claude/skills/issue-maker/modules/handoff.md#handoff-template
.claude/reference/chip-launching.md
EXPECTED
)
expected=$(printf '%s\n' "$expected" | sed "s#^#$ROOT/#")
assert_eq "$expected" "$actual" 'portable export reads only its module, bounded literal templates, and chip contract'

actual=$(cd /tmp && "$DISPATCH" update edit)
expected="$ROOT/.claude/skills/issue-maker/modules/update.md"
assert_eq "$expected" "$actual" 'dispatcher resolves modules from its install path outside the repo cwd'

# Parity guards for remote-write uncertainty and shared single/batch handoff gates.
assert_eq 0 "$(grep -q 'do not retry blindly' .claude/skills/issue-maker/modules/update.md; echo $?)" 'update uncertainty requires remote verification before logging'
assert_eq 0 "$(grep -q 'Immediately before applying a confirmed body edit' .claude/skills/issue-maker/modules/update.md; echo $?)" 'update refreshes the issue before applying a whole-body proposal'
assert_eq 0 "$(grep -q 'not compare-and-swap' .claude/skills/issue-maker/modules/update.md; echo $?)" 'update documents the GitHub whole-body concurrency limit'
assert_eq 0 "$(grep -q 'log state was not changed' .claude/skills/issue-maker/modules/retract.md; echo $?)" 'retract uncertainty leaves the log unchanged'
assert_eq 0 "$(grep -q 'chip-pending' .claude/skills/issue-maker/modules/retract.md; echo $?)" 'retract distinguishes pending chips before any release'
assert_eq 0 "$(grep -q 'Handoff recovery needed' .claude/skills/issue-maker/modules/session-state.md; echo $?)" 'compaction surfaces a persisted handoff reservation checkpoint'
assert_eq 0 "$(grep -q 'Resolve `active-work-cap.sh`' .claude/skills/issue-maker/modules/create/postfile.md; echo $?)" 'single and batch postfile share the cap census procedure'
assert_eq 0 "$(grep -q 'only on explicit request' .claude/skills/issue-maker/modules/batch.md; echo $?)" 'batch handoff wording keeps inline as the default'
assert_eq "$ROOT/.claude/skills/issue-maker/modules/session-mode.md" "$("$DISPATCH" session mode)" 'mode-switch requests dispatch to the dedicated mode module'
assert_eq 0 "$(grep -q 'switch to rapid-fire mode.*session:mode' .claude/skills/issue-maker/SKILL.md; echo $?)" 'entry classifies explicit mode switches'


set +e
"$DISPATCH" create unknown >/dev/null 2>&1
invalid_rc=$?
FAKE_SKILL="$(mktemp -d "${TMPDIR:-/tmp}/issue-maker-missing.XXXXXX")"
mkdir "$FAKE_SKILL/scripts"
cp "$DISPATCH" "$FAKE_SKILL/scripts/dispatch-module.sh"
(cd /tmp && "$FAKE_SKILL/scripts/dispatch-module.sh" update edit >/dev/null 2>&1)
missing_rc=$?
rm -f "$FAKE_SKILL/scripts/dispatch-module.sh"
rmdir "$FAKE_SKILL/scripts" "$FAKE_SKILL"
set -e
assert_eq 2 "$invalid_rc" 'invalid operation phase fails closed'
assert_eq 3 "$missing_rc" 'missing selected module fails closed with its path'

# The phase receipt uses the same atomic log writer as existing issue state.
STATE_LOG="$(mktemp "${TMPDIR:-/tmp}/issue-maker-state.XXXXXX")"
printf '%s\n' '{"target_repo":"owner/repo"}' > "$STATE_LOG"
SET_LOG="$ROOT/.claude/skills/issue-maker/scripts/set-log.sh"
"$SET_LOG" "$STATE_LOG" \
  '.checkpoint = {operation:$operation,module_phase:$phase,issue:(if $issue == "" then null else $issue end),repository:$repo,current_evidence:$evidence,next_step:$next}' \
  --arg operation update --arg phase edit --arg issue 42 --arg repo owner/repo \
  --arg evidence 'issue body fetched; pending user confirmation' --arg next 'present diff and wait for confirmation'
checkpoint=$(jq -c '.checkpoint' "$STATE_LOG")
expected='{"operation":"update","module_phase":"edit","issue":"42","repository":"owner/repo","current_evidence":"issue body fetched; pending user confirmation","next_step":"present diff and wait for confirmation"}'
assert_eq "$expected" "$checkpoint" 'phase checkpoint persists recovery fields atomically'
recovered_repo=$(jq -r '.target_repo // empty' "$STATE_LOG")
assert_eq 'owner/repo' "$recovered_repo" 'session recovery restores target repository from the log'

# A restarted context routes directly from the persisted checkpoint.
: > "$TRACE"
loaded=()
load_once session state
load_once "$(jq -r '.checkpoint.operation' "$STATE_LOG")" "$(jq -r '.checkpoint.module_phase' "$STATE_LOG")"
assert_eq "$ROOT/.claude/skills/issue-maker/modules/session-state.md
$ROOT/.claude/skills/issue-maker/modules/update.md" "$(cat "$TRACE")" 'compaction resumes only session and active update module'

rm -f "$STATE_LOG"

# Execute the production Markdown blocks against offline state and gh stubs.
# These validate state changes and failure behavior, not LLM prose inference.
python3 - "$ROOT" <<'PY'
import json, pathlib, re, shlex, shutil, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); skill=root/'.claude/skills/issue-maker'
def source(name): return (skill/name).read_text()
def blocks(name): return re.findall(r'```bash\n(.*?)\n\s*```', source(name), re.S)
def run(script,cwd=None): return subprocess.run(['bash','-eu','-c',script],text=True,capture_output=True,cwd=cwd)
selector=re.search(r"^MINE_DEF=.*$",source('modules/session-state.md'),re.M)[0]
with tempfile.TemporaryDirectory(prefix='issue-maker-behavior-') as td:
    log=pathlib.Path(td)/'log.json'
    setup=selector+'\n'+f'LOG={shlex.quote(str(log))}\nREPO=owner/repo\n'+f'set_log() {{ {shlex.quote(str(skill/"scripts/set-log.sh"))} "$LOG" "$@"; }}\n'
    def seed(rows): log.write_text(json.dumps({'issues':rows,'target_repo':'owner/repo'}))
    def row(n,**kw): return dict(number=n,title=f'Issue {n}',url=f'https://github.com/owner/repo/issues/{n}',status='open',chip_task_id=None,created_at='2026-10-30',**kw)
    # Threshold configuration is read from the target checkout only; a helper
    # installed elsewhere must not silently apply the invoking repo's policy.
    thresholds=next(b for b in blocks('modules/create/reflect-and-draft.md') if 'SPLIT_THRESHOLDS=' in b)
    th_home=pathlib.Path(td)/'threshold-home'; th_helper=th_home/'.claude/scripts/split-thresholds.sh'; th_helper.parent.mkdir(parents=True)
    th_args=pathlib.Path(td)/'threshold-args'
    th_helper.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > '+shlex.quote(str(th_args))+"\nprintf '{\\\"split_over_min\\\":240,\\\"increment_bound_min\\\":120}\\n'\n"); th_helper.chmod(0o755)
    git_stub='git() { if [[ "$1" == rev-parse ]]; then printf /target/root; else printf "%s" "$ORIGIN_URL"; fi; }\n'
    r=run('HOME='+shlex.quote(str(th_home))+'\nORIGIN_URL=git@github.com:owner/repo.git\n'+git_stub+setup+thresholds+'\nprintf "RESULT=%s/%s" "$SPLIT_OVER_MIN" "$INCREMENT_BOUND_MIN"')
    assert r.returncode==0 and r.stdout.endswith('RESULT=240/120') and th_args.read_text().splitlines()==['--json','--path','/target/root'],(r.returncode,r.stdout,r.stderr,th_args.read_text() if th_args.exists() else None)
    th_args.unlink()
    r=run('HOME='+shlex.quote(str(th_home))+'\nORIGIN_URL=git@github.com:other/repo.git\n'+git_stub+setup+thresholds+'\nprintf "RESULT=%s/%s" "$SPLIT_OVER_MIN" "$INCREMENT_BOUND_MIN"')
    assert r.returncode==0 and r.stdout.endswith('RESULT=180/120') and not th_args.exists() and 'current checkout does not match owner/repo' in r.stderr,(r.returncode,r.stdout,r.stderr)
    print('ok workflow: sizing reads target repo thresholds and degrades explicitly when checkout origin differs')
    seed([row(1,origin='create'),row(2,origin='update'),row(3),row(4,edited_at='2026-10-31'),row(5,edited_at='2026-10-31',tier='Light'),dict(row(6),url='https://github.com/other/repo/issues/6')])
    stamp=next(b for b in blocks('modules/create/postfile.md') if 'OFFER_TOKEN=' in b)
    r=run(setup+stamp); assert r.returncode==0,r.stderr
    rows=json.loads(log.read_text())['issues']
    assert [x['number'] for x in rows if x['chip_task_id']]==[1,3,5],rows
    cleanup='set_log "$MINE_DEF"\'(.issues[] | mine | .chip_task_id) = null\' --arg repo "$REPO"'
    r=run(setup+cleanup); assert r.returncode==0,r.stderr
    assert all(x['chip_task_id'] is None for x in json.loads(log.read_text())['issues'])
    print('ok workflow: offers and cleanup include filed/legacy-created rows, exclude update-only/foreign/ambiguous rows')
    fetch=blocks('modules/update.md')[0]
    r=run(setup+'\nN=42\nDELIVERS=stale\nEST_BOUND=300\ngh() { printf \'%s\' \'{"title":"Fetched title","url":"https://github.com/owner/repo/issues/42","state":"CLOSED","body":"old body"}\'; }\n'+fetch+'\nprintf \'%s|%s|%s|%s|%s\' "$TITLE" "$ISSUE_URL" "$ISSUE_STATUS" "$DELIVERS" "$EST_BOUND"')
    assert r.returncode==0 and r.stdout=='Fetched title|https://github.com/owner/repo/issues/42|closed||',(r.stdout,r.stderr)
    update=next(b for b in blocks('modules/update.md') if 'set_log' in b)
    seed([dict(row(42),url='https://github.com/foreign/repo/issues/42')])
    before=json.loads(log.read_text())['issues'][0]
    r=run(setup+'N=42\nTITLE="Fetched title"\nISSUE_URL=https://github.com/owner/repo/issues/42\nISSUE_STATUS=closed\n'+update)
    assert r.returncode==0,r.stderr
    rows=json.loads(log.read_text())['issues']; assert rows[0]==before and rows[1]['origin']=='update' and rows[1]['title']=='Fetched title' and rows[1]['status']=='closed',rows
    print('ok workflow: update fetch assigns metadata and backfills the right repo without creating offered work')
    # A mode switch is a persisted session operation, not an initial-argument re-seed.
    seed([]); data=json.loads(log.read_text()); data['mode']='default'; log.write_text(json.dumps(data))
    mode_block=blocks('modules/session-mode.md')[0]
    r=run(setup+'REQUESTED_MODE=rapid-fire\n'+mode_block+'\nprintf "%s" "$MODE"')
    assert r.returncode==0 and r.stdout=='rapid-fire' and json.loads(log.read_text())['mode']=='rapid-fire',(r.stdout,r.stderr,log.read_text())
    r=run(setup+'REQUESTED_MODE=default\n'+mode_block+'\nprintf "%s" "$MODE"')
    assert r.returncode==0 and r.stdout=='default' and json.loads(log.read_text())['mode']=='default',(r.stdout,r.stderr,log.read_text())
    print('ok workflow: explicit mode switches persist in the recovered session log')
    # Session helper resolution follows the selected dispatcher root, even when
    # the invocation runs outside the repository or uses an installed copy.
    resolve_setup=blocks('modules/session-state.md')[0]
    writer_setup=next(b for b in blocks('modules/session-state.md') if 'SET_LOG=""' in b)
    installed=pathlib.Path(td)/'installed/.claude/skills/issue-maker'; (installed/'scripts').mkdir(parents=True)
    for name in ['dispatch-module.sh','resolve-log.sh','set-log.sh']:
        shutil.copy2(skill/'scripts'/name,installed/'scripts'/name)
    for label,skill_root,home in [('bundled',skill,pathlib.Path(td)/'home-bundled'),('installed',installed,pathlib.Path(td)/'home-installed')]:
        home.mkdir(parents=True)
        dispatcher=skill_root/'scripts/dispatch-module.sh'
        r=run('export HOME='+shlex.quote(str(home))+'\nexport DISPATCHER='+shlex.quote(str(dispatcher.resolve()))+'\nexport CLAUDE_SESSION_ID=local-'+label+'\n'+resolve_setup+'\nprintf "RESOLVE=%s|LOG=%s|SESSION=%s" "$RESOLVE_LOG" "$LOG" "$SESSION_ID"',cwd='/tmp')
        fields=dict(part.split('=',1) for part in r.stdout.split('|')) if r.stdout else {}
        assert r.returncode==0 and fields.get('RESOLVE')==str((skill_root/'scripts/resolve-log.sh').resolve()) and fields.get('SESSION'),(label,r.returncode,r.stdout,r.stderr)
        helper_log=home/'.claude/handoffs/writer-check.json'; helper_log.parent.mkdir(parents=True,exist_ok=True); helper_log.write_text('{"issues":[]}')
        r=run('export HOME='+shlex.quote(str(home))+'\nexport DISPATCHER='+shlex.quote(str(dispatcher.resolve()))+'\nLOG='+shlex.quote(str(helper_log))+'\n'+writer_setup+'\nset_log \'.mode = $v\' --arg v rapid-fire\nprintf "%s" "$SET_LOG"',cwd='/tmp')
        assert r.returncode==0 and r.stdout==str((skill_root/'scripts/set-log.sh').resolve()) and json.loads(helper_log.read_text())['mode']=='rapid-fire',(label,r.returncode,r.stdout,r.stderr,helper_log.read_text())
    print('ok workflow: bundled and installed invocations resolve session helpers from DISPATCHER outside the repo cwd')
    # Offer acceptance is one atomic, checked write for both state changes.
    seed([dict(row(1,origin='create'),chip_task_id='offer-token'),dict(row(2,origin='create'),chip_task_id='foreign-token',url='https://github.com/other/repo/issues/2')])
    accept=next(b for b in blocks('modules/create/postfile.md') if "offer_accepted = true |" in b)
    r=run(setup+accept)
    data=json.loads(log.read_text()); assert r.returncode==0 and data['offer_accepted'] is True and data['issues'][0]['chip_task_id'] is None and data['issues'][1]['chip_task_id']=='foreign-token',(r.stdout,r.stderr,data)
    calls=pathlib.Path(td)/'accept-calls'; failing='set_log() { printf x >> '+shlex.quote(str(calls))+'; return 1; }\n'
    r=run(setup+failing+accept+'\nprintf AFTER')
    assert r.returncode==1 and 'AFTER' not in r.stdout and calls.read_text()=='x' and 'started' in r.stderr,(r.returncode,r.stdout,r.stderr)
    print('ok workflow: acceptance and token cleanup share one checked write; failed persistence stops')
    close=next(b for b in blocks('modules/retract.md') if 'if ! gh issue close' in b)
    for remote,view_rc,expected_rc,expected_status in [('OPEN',0,1,'open'),('',1,1,'open'),('CLOSED',0,0,'closed')]:
        seed([dict(row(42,origin='create'),chip_task_id='offer-original')]); before=log.read_bytes()
        gh='gh() { if [[ "$2" == close ]]; then return 1; fi; printf \'%s\' '+shlex.quote(remote)+'; return '+str(view_rc)+'; }\n'
        r=run(setup+'N=42\n'+gh+close)
        assert r.returncode==expected_rc,(r.returncode,r.stderr)
        rows=json.loads(log.read_text())['issues']; assert rows[0]['status']==expected_status and rows[0]['chip_task_id']=='offer-original',rows
        if expected_rc: assert log.read_bytes()==before,'uncertain or failed close mutated state'
    print('ok workflow: failed/uncertain close leaves state byte-identical; verified lost response logs only closed status and retains cleanup token')
    seed([row(42,origin='create',chain={'chain_id':'c','position':1,'total':2})])
    data=json.loads(log.read_text()); data['active_chain']={'chain_id':'c','total':2,'repository':'owner/repo'}; log.write_text(json.dumps(data))
    r=run(setup+'N=42\nCHAIN_ID=c\ngh() { return 0; }\n'+close)
    data=json.loads(log.read_text()); assert r.returncode==0 and data['issues'][0]['status']=='closed' and data['active_chain'] is None,(r.stderr,data)
    print('ok workflow: retracting the last filed member clears its cancelled active-chain recovery receipt')
    seed([row(42,origin='create',chain={'chain_id':'c','position':3,'total':4}),dict(row(42,origin='create',chain={'chain_id':'c','position':3,'total':4}),url='https://github.com/foreign/repo/issues/42')])
    data=json.loads(log.read_text()); data['active_chain']={'chain_id':'c','total':4,'repository':'owner/repo'}; log.write_text(json.dumps(data))
    recut=next(b for b in blocks('modules/retract.md') if 'SURVIVOR_N' in b)
    r=run(setup+'SURVIVOR_N=42\nCHAIN_ID=c\nNEW_TITLE="Theme 2/3"\nNEW_POSITION=2\nNEW_TOTAL=3\n'+recut);assert r.returncode==0,r.stderr
    data=json.loads(log.read_text()); rows=data['issues']; assert rows[0]['title']=='Theme 2/3' and rows[0]['chain']=={'chain_id':'c','position':2,'total':3} and rows[1]['chain']['position']==3 and data['active_chain']['total']==3,(rows,data)
    print('ok workflow: re-cut updates survivor title, coordinates, and active plan total together')
    # First handoff emission after a declined inline offer has no token to reuse.
    seed([row(1,origin='create'),row(2,origin='update')])
    release_block=next(b for b in blocks('modules/handoff.md') if 'handoff_release_unstarted()' in b)
    handoff_stamp=release_block+'\n'+next(b for b in blocks('modules/handoff.md') if 'OFFER_TOKEN=' in b)
    r=run(setup+'CHIP_TOOL_AVAILABLE=false\nISSUE_ARGS=()\n'+handoff_stamp); assert r.returncode==0,r.stderr
    rows=json.loads(log.read_text())['issues']; assert rows[0]['chip_task_id'].startswith('offer-') and rows[1]['chip_task_id'] is None
    print('ok workflow: explicit fallback handoff after decline stamps only session-filed rows')
    # Execute the production reservation/stamp/launch/receipt/cleanup fences with
    # the REAL registry helper. Only boundary failures are injected by a shim.
    home=pathlib.Path(td)/'reserve-home'; registry=home/'.claude/skills-worktree/.claude/scripts/chip-offer-registry.sh'; registry.parent.mkdir(parents=True)
    cap=registry.parent/'active-work-cap.sh'; cap_args=pathlib.Path(td)/'cap-args'
    cap.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > '+shlex.quote(str(cap_args))+'\nprintf \'{"free":1,"registry_baseline":0}\\n\'\n'); cap.chmod(0o755)
    registry_args=pathlib.Path(td)/'registry-args'
    registry.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> '''+shlex.quote(str(registry_args))+'''
case " $* " in
  *" --reserve "*)
    [[ "${FAULT:-}" == deny ]] && exit 7
    if [[ "${FAULT:-}" == reserve-lost ]]; then bash '''+shlex.quote(str(root/'.claude/scripts/chip-offer-registry.sh'))+''' "$@" >/dev/null; exit 4; fi ;;
  *" --list "*) [[ "${FAULT:-}" == list-fail ]] && exit 4 ;;
  *" --retract "*) [[ "${FAULT:-}" == retract-fail ]] && exit 4 ;;
esac
exec bash '''+shlex.quote(str(root/'.claude/scripts/chip-offer-registry.sh'))+''' "$@"
'''); registry.chmod(0o755)
    env_setup='export HOME='+shlex.quote(str(home))+'\nCHIP_TOOL_AVAILABLE=true\n'
    state_file=home/'.claude/session-state.json'
    def fresh():
        seed([row(1,origin='create'),row(2,origin='update'),dict(row(3,origin='create'),url='https://github.com/foreign/repo/issues/3')])
        state_file.write_text('{"repos":{"foreign/repo":{"chip_offers":[{"task_id":"foreign","state":"running"}]}}}')
        registry_args.write_text('')
    def offers(): return json.loads(state_file.read_text())['repos'].get('owner/repo',{}).get('chip_offers',[])
    def invoke(extra='',body=handoff_stamp): return run(setup+env_setup+extra+'\n'+body)
    launch=next(b for b in blocks('modules/handoff.md') if '.delivery_mode = "chip-pending"' in b)
    receipt=next(b for b in blocks('modules/handoff.md') if '.delivery_mode = "chip" | .reg_tid = $reg' in b)
    fallback=next(b for b in blocks('modules/handoff.md') if 'SPAWN_OUTCOME' in b)
    # A resolved-but-unreadable cap never takes the uncounted admission path.
    cap_good=cap.read_text();cap.write_text('#!/usr/bin/env bash\nexit 4\n')
    fresh();r=invoke();assert r.returncode==1 and not offers() and not registry_args.read_text()
    cap.write_text(cap_good)
    # Failure before reservation intent cannot write either external store.
    fresh(); r=invoke('set_log() { return 1; }'); assert r.returncode==1 and not offers() and not registry_args.read_text()
    # A cap race may checkpoint admission intent but never stamps/emits or leaks a slot.
    fresh();r=invoke('export FAULT=deny');d=json.loads(log.read_text());assert r.returncode==7 and d.get('reg_tid') is None and d['issues'][0]['chip_task_id'] is None and not offers(),(r.stderr,d)
    assert cap_args.read_text().splitlines()==['--json','--repo','owner/repo']
    # Lost successful reserve response is reconciled by exact caller ID, not retried.
    fresh();r=invoke('export FAULT=reserve-lost');d=json.loads(log.read_text());assert r.returncode==0 and len(offers())==1 and d['reg_tid']==offers()[0]['task_id'] and d['delivery_mode']=='chip-reserved' and offers()[0]['issues']==[1],(r.stderr,d,offers())
    assert d['issues'][1]['chip_task_id'] is None and d['issues'][2]['chip_task_id'] is None
    # Restart before any spawn is described as reservation, never a started chip.
    recovery=next(b for b in blocks('modules/session-state.md') if 'if [ -f "$LOG" ]' in b)
    r=run(setup+recovery);assert r.returncode==0 and 'capacity reserved; no spawn confirmed' in r.stdout and 'chip started' not in r.stdout,r.stdout
    before=log.read_bytes();r=invoke();assert r.returncode==1 and log.read_bytes()==before and len(offers())==1
    # Unknown registry read preserves intent and blocks a launch (no stamp yet).
    fresh();r=invoke('export FAULT=list-fail');d=json.loads(log.read_text());assert r.returncode==1 and d['handoff_checkpoint']['state']=='reservation-intent' and d['issues'][0]['chip_task_id'] is None and len(offers())==1
    # Failed offer stamp with confirmed release clears the pre-persisted receipt.
    fail_stamp='set_log() { if [[ "$1" == *"chip_task_id) = $tok"* ]]; then return 1; fi; '+shlex.quote(str(skill/'scripts/set-log.sh'))+' "$LOG" "$@"; }'
    # Literal $tok must be matched, not expanded under nounset.
    fail_stamp=fail_stamp.replace('== *"chip_task_id) = $tok"*','== *\'chip_task_id) = $tok\'*')
    fresh();r=invoke(fail_stamp);d=json.loads(log.read_text());assert r.returncode==1 and d['reg_tid'] is None and d['handoff_checkpoint'] is None and offers()[0]['state']=='retracted' and d['issues'][0]['chip_task_id'] is None,(r.stderr,d,offers())
    fresh();r=invoke('export FAULT=retract-fail\n'+fail_stamp);d=json.loads(log.read_text());assert r.returncode==1 and d['reg_tid'] and d['handoff_checkpoint']['state']=='cleanup-pending' and d['handoff_checkpoint']['spawn_status']=='not-started' and offers()[0]['state']=='offered'
    # A failed local cleanup after successful retract retains enough for restart.
    fresh();r=invoke(fail_stamp.replace("then return 1; fi;", "then return 1; fi; if [[ \"$1\" == '.reg_tid = null'* ]]; then return 1; fi;",1));d=json.loads(log.read_text());assert r.returncode==1 and d['reg_tid'] and offers()[0]['state']=='retracted'
    # Pre-tool intent failure stops; no tool was invoked and reservation is released.
    fresh();r=invoke();assert r.returncode==0,r.stderr
    reg=json.loads(log.read_text())['reg_tid']; base_state=log.read_bytes(); base_registry=state_file.read_bytes()
    def saved(): log.write_bytes(base_state);state_file.write_bytes(base_registry)
    launch_fail='set_log() { if [[ "$1" == *\'spawn-uncertain\'* ]]; then return 1; fi; '+shlex.quote(str(skill/'scripts/set-log.sh'))+' "$LOG" "$@"; }'
    r=invoke('REGISTRY='+shlex.quote(str(registry))+'\nREG_TID='+shlex.quote(reg)+'\n'+launch_fail,release_block+'\n'+launch);assert r.returncode==1 and offers()[0]['state']=='retracted'
    # A restart during tool invocation has unknown outcome; fallback cannot release it.
    saved();r=invoke('',launch);assert r.returncode==0,r.stderr
    pending_state=log.read_bytes();r=run(setup+recovery);assert 'spawn outcome unknown' in r.stdout and 'chip started' not in r.stdout,r.stdout
    r=invoke('REGISTRY='+shlex.quote(str(registry))+'\nREG_TID='+shlex.quote(reg)+'\nSPAWN_OUTCOME=unknown',release_block+'\n'+fallback);assert r.returncode==1 and log.read_bytes()==pending_state and offers()[0]['state']=='offered'
    # The release helper itself refuses unknown spawn and wrong-repo identities.
    for guard_args in ('','REPO=other/repo\n'):
        r=invoke('REGISTRY='+shlex.quote(str(registry))+'\nREG_TID='+shlex.quote(reg)+'\n'+guard_args,release_block+'\nhandoff_release_unstarted')
        assert r.returncode==1 and log.read_bytes()==pending_state and offers()[0]['state']=='offered'
    # Inline refresh/accept/decline cannot overwrite a pending chip receipt.
    for inline_block in [b for b in blocks('modules/create/postfile.md') if 'HOLD: reconcile existing chip' in b]:
        r=run(setup+inline_block);assert r.returncode==1 and log.read_bytes()==pending_state,(r.stderr,log.read_text())
    # A malformed atomic update leaves the prior log intact and no temp file.
    before=log.read_bytes();r=run(setup+"set_log 'this is invalid jq'\n")
    assert r.returncode!=0 and log.read_bytes()==before and not list(log.parent.glob(log.name+'.tmp.*'))
    # Confirmed spawn, failed primary receipt, and failed BOTH writes retain reg ID.
    for failure in ('none','first','all'):
        log.write_bytes(pending_state);state_file.write_bytes(base_registry)
        fail='' if failure=='none' else ('set_log() { return 1; }' if failure=='all' else 'set_log() { if [[ "$1" == *\'.delivery_mode = "chip" |\'* ]]; then return 1; fi; '+shlex.quote(str(skill/'scripts/set-log.sh'))+' "$LOG" "$@"; }')
        r=invoke('REG_TID='+shlex.quote(reg)+'\nTASK_ID=task-confirmed\n'+fail,receipt);d=json.loads(log.read_text())
        assert d['reg_tid']==reg and offers()[0]['state']=='offered'
        assert (r.returncode,d['handoff_checkpoint']['state'])==((0,'spawned') if failure=='none' else (1,'spawned-receipt-pending' if failure=='first' else 'spawn-uncertain')),(r.stderr,d)
        rec=run(setup+recovery);assert ('spawn outcome unknown' in rec.stdout)==(failure=='all'),rec.stdout
    # Explicit no-creation response releases and leaves the copyable offer token.
    log.write_bytes(pending_state);state_file.write_bytes(base_registry)
    r=invoke('REGISTRY='+shlex.quote(str(registry))+'\nREG_TID='+shlex.quote(reg)+'\nSPAWN_OUTCOME=not-started',release_block+'\n'+fallback);d=json.loads(log.read_text());assert r.returncode==0 and d['reg_tid'] is None and d['delivery_mode']=='inline' and d['issues'][0]['chip_task_id'].startswith('offer-') and offers()[0]['state']=='retracted'
    # Retract after confirmed remote close: reserved can release; unknown/spawned cannot.
    retract_cleanup=next(b for b in blocks('modules/retract.md') if 'CLOSED_NUMBERS_JSON=' in b)
    for mode,status,should_release in [('chip-reserved','not-started',True),('chip-pending','unknown',False),('chip','spawned',False)]:
        saved();d=json.loads(log.read_text());d['issues'][0]['status']='closed';d['delivery_mode']=mode;d['handoff_checkpoint']['spawn_status']=status;log.write_text(json.dumps(d))
        tok=d['issues'][0]['chip_task_id'];r=invoke('N=1\nSHARERS=0\nOFFER_TOKEN='+shlex.quote(tok),retract_cleanup);after=json.loads(log.read_text())
        assert (r.returncode==0)==should_release,(r.stderr,after)
        assert offers()[0]['state']==('retracted' if should_release else 'offered')
        assert (after['issues'][0]['chip_task_id'] is None)==should_release
    # Receipt ownership and every external registry operation are exact-repo scoped.
    for line in registry_args.read_text().splitlines(): assert line.startswith('--repo owner/repo '),line
    assert json.loads(state_file.read_text())['repos']['foreign/repo']['chip_offers'][0]['state']=='running'
    print('ok workflow: real registry reservation/stamp/spawn/recovery/retract failure matrix preserves ownership and truthful monotonic receipts')
    # Execute the actual filing block with a missing postfile module: no gh write.
    fake=pathlib.Path(td)/'skill'; (fake/'scripts').mkdir(parents=True)
    dispatcher=fake/'scripts/dispatch-module.sh'; dispatcher.write_text((skill/'scripts/dispatch-module.sh').read_text())
    create_block=next(b for b in blocks('modules/create/file.md') if 'FILED=$(' in b)
    r=run('DISPATCHER='+shlex.quote(str(dispatcher))+'\n'+create_block)
    assert r.returncode==3 and 'required module missing' in r.stderr,(r.returncode,r.stderr)
    print('ok workflow: missing postfile dependency exits before the actual create block can call GitHub')
    recovery=next(b for b in blocks('modules/session-state.md') if 'if [ -f "$LOG" ]' in b)
    seed([]); data=json.loads(log.read_text()); data['target_repo']=''; log.write_text(json.dumps(data)); before=log.read_bytes()
    r=run(setup+recovery)
    assert r.returncode==1 and log.read_bytes()==before and 'no target repository' in r.stderr,(r.returncode,r.stderr)
    print('ok workflow: recovery with unknown target repository refuses operation work without mutating state')

    # A user-supplied retarget is validated before the first target_repo write.
    retarget=next(b for b in blocks('modules/session-state.md') if 'FOREIGN=$(jq' in b)
    retarget=retarget.replace('REPO="<owner/repo the user supplied>"','REPO="__TEST_REPO__"')
    seed([]); before=log.read_bytes()
    r=run(setup+retarget.replace('__TEST_REPO__','https://github.com/owner/repo'))
    assert r.returncode==1 and log.read_bytes()==before and 'expected owner/repo' in r.stderr,(r.returncode,r.stderr)
    r=run(setup+retarget.replace('__TEST_REPO__','new-owner/new-repo'))
    assert r.returncode==0 and json.loads(log.read_text())['target_repo']=='new-owner/new-repo',(r.returncode,r.stderr,log.read_text())
    print('ok workflow: retarget validates slug format before mutation and stores a valid owner/repo')

    # Siblings are excluded before the helper's result cap and in fallback results.
    seed([row(11,origin='create',chain={'chain_id':'chain-a','position':1,'total':3}),row(12,origin='create',chain={'chain_id':'chain-a','position':2,'total':3}),row(13,origin='create',chain={'chain_id':'chain-b','position':1,'total':2})])
    home=pathlib.Path(td)/'dedup-home'; helper=home/'.claude/scripts/issue-dedup.sh'; helper.parent.mkdir(parents=True); args_file=pathlib.Path(td)/'dedup-args'
    helper.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" > '+shlex.quote(str(args_file))+'\n'); helper.chmod(0o755)
    dedup=blocks('modules/create/dedup.md')[0].replace('KEYWORDS="<significant words from the title and problem statement>"','KEYWORDS="alpha beta"')
    r=run(setup+'HOME='+shlex.quote(str(home))+'\nCHAIN_ID=chain-a\n'+dedup)
    assert r.returncode==0 and args_file.read_text().splitlines()==['alpha beta','--repo','owner/repo','--exclude','11,12'],(r.returncode,r.stderr,args_file.read_text() if args_file.exists() else None)
    fallback=blocks('modules/create/dedup.md')[1]
    r=run('REPO=owner/repo\nKEYWORDS=alpha\nSIBLING_NUMBERS=11,12\nCANDIDATES='+shlex.quote('[{"number":11,"state":"OPEN"},{"number":13,"state":"OPEN"},{"number":14,"state":"CLOSED","closedAt":"2020-01-01T00:00:00Z"}]')+'\ngh() { printf "%s" "$CANDIDATES"; }\n'+fallback+'\nprintf "%s" "$CANDIDATES"')
    assert r.returncode==0 and json.loads(r.stdout)==[{'number':13,'state':'OPEN'}],(r.stdout,r.stderr)
    print('ok workflow: chain siblings reach helper exclusion before its cap and are filtered from fallback candidates')

    # The body delimiter is chosen after content exists; even the former marker
    # and shell-looking body lines remain literal file content.
    create_block=next(b for b in blocks('modules/create/file.md') if 'FILED=$(' in b)
    marker='ISSUE_BODY_7f34d1c9'; unique='ISSUE_BODY_generated_42'
    create_block=create_block.replace(marker,unique)
    body='## Background\n'+marker+'\n$(touch '+str(pathlib.Path(td)/'body-executed')+')\n_Captured via /issue-maker._'
    create_block=create_block.replace('## Background\n...\n_Captured via /issue-maker._',body)
    home=pathlib.Path(td)/'file-home'; helper=home/'.claude/skills-worktree/.claude/scripts/issue-file.sh'; helper.parent.mkdir(parents=True)
    captured=pathlib.Path(td)/'captured-body'
    helper.write_text('#!/usr/bin/env bash\nwhile [ "$#" -gt 0 ]; do case "$1" in --body-file) cp "$2" '+shlex.quote(str(captured))+'; shift 2;; *) shift;; esac; done\nprintf \'{"url":"https://github.com/owner/repo/issues/7","number":7,"labels":[]}\'\n'); helper.chmod(0o755)
    dispatcher=pathlib.Path(td)/'dispatcher.sh'; dispatcher.write_text('#!/usr/bin/env bash\nexit 0\n'); dispatcher.chmod(0o755)
    r=run('HOME='+shlex.quote(str(home))+'\nDISPATCHER='+shlex.quote(str(dispatcher))+'\nREPO=owner/repo\nTITLE="Safe title"\nACCEPTED_LABELS=""\n'+create_block)
    assert r.returncode==0 and not (pathlib.Path(td)/'body-executed').exists() and marker in captured.read_text() and '$(touch' in captured.read_text(),(r.returncode,r.stdout,r.stderr,captured.read_text() if captured.exists() else None)
    print('ok workflow: generated quoted heredoc delimiter keeps delimiter-like and shell-looking issue body lines literal')

    # The issue-file phase and postfile phase run as separate invocations. The
    # structured receipt output must carry the remote write across that boundary.
    receipt_line=next(line for line in r.stdout.splitlines() if line.startswith('CREATE_RECEIPT='))
    receipt=json.loads(receipt_line.split('=',1)[1])
    assert receipt=={'number':7,'url':'https://github.com/owner/repo/issues/7','title':'Safe title','labels':[]},receipt
    seed([])
    record=next(b for b in blocks('modules/create/postfile.md') if '.issues +=' in b)
    restore='CREATE_RECEIPT='+shlex.quote(json.dumps(receipt))+'\n'
    restore+='ISSUE_NUMBER=$(printf %s "$CREATE_RECEIPT" | jq -er .number)\n'
    restore+='ISSUE_URL=$(printf %s "$CREATE_RECEIPT" | jq -er .url)\n'
    restore+='TITLE=$(printf %s "$CREATE_RECEIPT" | jq -er .title)\n'
    restore+='ACCEPTED_LABELS=$(printf %s "$CREATE_RECEIPT" | jq -r \' .labels[]? \')\n'
    restore+='CHAIN_JSON=null\nIS_INCREMENT=false\nISSUE_TIER=Light\nDELIVERS="Safe issue receipt"\nEST_BOUND=60\n'
    recorded=run(setup+restore+record)
    rows=json.loads(log.read_text())['issues']
    assert recorded.returncode==0 and len(rows)==1 and rows[0]['number']==7 and rows[0]['url']==receipt['url'],(recorded.returncode,recorded.stderr,rows)
    print('ok workflow: create receipt survives a separate postfile invocation and records the confirmed issue')

    # Uncertain create reconciliation compares the body byte-for-byte from its
    # file and fails closed for same-second exact duplicates from another session.
    create_block=next(b for b in blocks('modules/create/file.md') if 'FILED=$(' in b)
    body='## Background\nbody\n_Captured via /issue-maker._\n'
    create_block=create_block.replace('## Background\n...\n_Captured via /issue-maker._',body)
    home=pathlib.Path(td)/'recover-home'; helper=home/'.claude/skills-worktree/.claude/scripts/issue-file.sh'; helper.parent.mkdir(parents=True)
    helper.write_text('#!/usr/bin/env bash\nexit 4\n'); helper.chmod(0o755)
    dispatcher=pathlib.Path(td)/'dispatcher.sh'; dispatcher.write_text('#!/usr/bin/env bash\nexit 0\n'); dispatcher.chmod(0o755)
    candidate={'number':8,'url':'https://github.com/owner/repo/issues/8','title':'Safe title','body':body+'\n','createdAt':'2026-10-30T12:00:01Z','labels':[]}
    def recovery_env(candidate):
        payload=json.dumps([candidate])
        return 'HOME='+shlex.quote(str(home))+'\nDISPATCHER='+shlex.quote(str(dispatcher))+'\nREPO=owner/repo\nTITLE="Safe title"\nACCEPTED_LABELS=""\ndate() { printf "2026-10-30T12:00:00Z"; }\ngh() { printf %s '+shlex.quote(payload)+'; }\n'
    env=recovery_env(candidate)
    r=run(env+create_block)
    assert r.returncode==0 and 'FILE_RC=0' in r.stdout and 'CREATE_RECEIPT={"number":8,"url":"https://github.com/owner/repo/issues/8","title":"Safe title","labels":[]}' in r.stdout,(r.returncode,r.stdout,r.stderr)
    # Same-second candidate is ambiguous and therefore cannot be claimed.
    candidate['createdAt']='2026-10-30T12:00:00Z'
    env=recovery_env(candidate)
    r=run(env+create_block)
    assert r.returncode==0 and 'FILE_RC=6' in r.stdout and 'exact matches' in r.stderr,(r.returncode,r.stdout,r.stderr)
    # A body with a missing trailing newline is not normalized into a match.
    candidate['body']=body.rstrip('\n'); candidate['createdAt']='2026-10-30T12:00:01Z'
    env=recovery_env(candidate)
    r=run(env+create_block)
    assert r.returncode==0 and 'FILE_RC=6' in r.stdout,(r.returncode,r.stdout,r.stderr)
    print('ok workflow: uncertain create recovery preserves body newlines and rejects same-second ownership ambiguity')

    # Update apply refetches and checks both remote fields before the receipt path.
    update_apply=next(b for b in blocks('modules/update.md') if 'UPDATE_KIND' in b)
    update_args=pathlib.Path(td)/'update-args'
    ghstub='gh() { if [[ "$2" == edit ]]; then printf "%s\\n" "$@" > '+shlex.quote(str(update_args))+'; return 4; fi; printf \'%s\' "$REMOTE_JSON"; }\n'
    remote=json.dumps({'title':'Proposed title','body':'confirmed body','url':'https://github.com/owner/repo/issues/42','state':'OPEN'})
    r=run('N=42\nREPO=owner/repo\nTITLE="Old title"\nNEW_TITLE="Proposed title"\nNEW_BODY="confirmed body"\nREMOTE_JSON='+shlex.quote(remote)+'\n'+ghstub+update_apply+'\nprintf "%s|%s|%s" "$TITLE" "$ISSUE_URL" "$ISSUE_STATUS"')
    assert r.returncode==0 and r.stdout=='Proposed title|https://github.com/owner/repo/issues/42|open' and update_args.read_text().splitlines()==['issue','edit','42','--repo','owner/repo','--title','Proposed title','--body','confirmed body'],(r.stdout,r.stderr,update_args.read_text())
    r=run('N=42\nREPO=owner/repo\nTITLE="Old title"\nNEW_TITLE="Proposed title"\nNEW_BODY="confirmed body"\nREMOTE_JSON='+shlex.quote(json.dumps({**json.loads(remote),'title':'Stale title'}))+'\n'+ghstub+update_apply)
    assert r.returncode==1 and 'no session receipt was written' in r.stderr,(r.returncode,r.stderr)
    print('ok workflow: update accepts a verified title/body after uncertain write and rejects stale remote state')

    # A chain identity exists before dedup; recovery restores it without minting.
    seed([])
    init=blocks('modules/create/increment-draft.md')[0]
    r=run('set +e\nTOTAL=2\nREPO=owner/repo\nset_log() { return 1; }\n'+init+'\nprintf AFTER')
    assert r.returncode==1 and 'AFTER' not in r.stdout and 'could not persist the active chain' in r.stderr,(r.returncode,r.stdout,r.stderr)
    print('ok workflow: failed active-chain receipt stops before dedup/file')
    r=run(setup+'TOTAL=2\n'+init+'\nprintf \'%s\' "$CHAIN_ID"'); assert r.returncode==0,r.stderr
    chain_id=r.stdout; assert json.loads(log.read_text())['active_chain']['chain_id']==chain_id
    r=run(setup+recovery+'\nprintf \'RESTORED=%s|%s|%s\' "$CHAIN_ID" "$TOTAL" "$POSITION"')
    assert r.returncode==0 and 'RESTORED='+chain_id+'|2|1' in r.stdout,(r.stdout,r.stderr)
    chain_init=next(b for b in blocks('modules/create/postfile.md') if 'CHAIN_JSON=null' in b)
    r=run(setup+'IS_INCREMENT=true\nCHAIN_ID='+shlex.quote(chain_id)+'\nPOSITION=1\nTOTAL=2\n'+chain_init+'\nprintf \'%s\' "$CHAIN_JSON"')
    assert r.returncode==0 and json.loads(r.stdout)=={'chain_id':chain_id,'position':1,'total':2},(r.stdout,r.stderr)
    r=run(setup+'IS_INCREMENT=false\nCHAIN_JSON=stale\n'+chain_init+'\nprintf \'%s\' "$CHAIN_JSON"')
    assert r.returncode==0 and r.stdout=='null',(r.stdout,r.stderr)
    record=next(b for b in blocks('modules/create/postfile.md') if "set_log '.issues +=" in b)
    for position in [1,2]:
        params='IS_INCREMENT=true\nCHAIN_ID='+shlex.quote(chain_id)+'\nPOSITION='+str(position)+'\nTOTAL=2\nISSUE_NUMBER='+str(position)+'\nTITLE=Increment\nISSUE_URL=https://github.com/owner/repo/issues/'+str(position)+'\nACCEPTED_LABELS=""\nISSUE_TIER=Light\nDELIVERS=Slice\nEST_BOUND=60\n'
        r=run(setup+params+chain_init+'\n'+record); assert r.returncode==0,r.stderr
        data=json.loads(log.read_text())
        assert data['issues'][-1]['chain']=={'chain_id':chain_id,'position':position,'total':2}
        assert (data['active_chain'] is None)==(position==2)
    print('ok workflow: chain identity precedes dedup, survives phase recovery, and record initialization clears stale standalone metadata')
    labels=blocks('modules/create/file.md')[0]
    gh_labels='gh() { if [[ " $* " == *" --limit 1000 "* ]]; then printf \'first\nlabel-after-30\n\'; else printf \'first\n\'; fi; }\n'
    r=run(setup+gh_labels+labels+'\nprintf \'%s\' "$REPO_LABELS"')
    assert r.returncode==0 and 'label-after-30' in r.stdout,(r.stdout,r.stderr)
    print('ok workflow: label prefetch includes names beyond gh default first page with the shared helper bound')
    assert 'FILED=$(' not in source('modules/create/reflect-and-draft.md')
    assert 'Finalize sizing only after the estimate exists' in source('modules/create/reflect-and-draft.md')
    # Guard the executable remote write's phase placement rather than a copied implementation.
    assert 'issue-maker-create' in source('modules/create/file.md')
    print('ok workflow: reflection contains no create invocation; estimate precedes final sizing and file phase owns the write')
PY

if (( fail > 0 )); then
  printf '\n%d/%d checks failed\n' "$fail" "$total" >&2
  exit 1
fi
printf '\n%d checks passed\n' "$total"
