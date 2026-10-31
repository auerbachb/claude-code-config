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
assert_eq 0 "$(grep -q 'log state was not changed' .claude/skills/issue-maker/modules/retract.md; echo $?)" 'retract uncertainty leaves the log unchanged'
assert_eq 0 "$(grep -q 'Resolve `active-work-cap.sh`' .claude/skills/issue-maker/modules/create/postfile.md; echo $?)" 'single and batch postfile share the cap census procedure'
assert_eq 0 "$(grep -q 'only on explicit request' .claude/skills/issue-maker/modules/batch.md; echo $?)" 'batch handoff wording keeps inline as the default'


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
import json, pathlib, re, shlex, subprocess, sys, tempfile
root=pathlib.Path(sys.argv[1]); skill=root/'.claude/skills/issue-maker'
def source(name): return (skill/name).read_text()
def blocks(name): return re.findall(r'```bash\n(.*?)\n\s*```', source(name), re.S)
def run(script): return subprocess.run(['bash','-eu','-c',script],text=True,capture_output=True)
selector=re.search(r"^MINE_DEF=.*$",source('modules/session-state.md'),re.M)[0]
with tempfile.TemporaryDirectory(prefix='issue-maker-behavior-') as td:
    log=pathlib.Path(td)/'log.json'
    setup=selector+'\n'+f'LOG={shlex.quote(str(log))}\nREPO=owner/repo\n'+f'set_log() {{ {shlex.quote(str(skill/"scripts/set-log.sh"))} "$LOG" "$@"; }}\n'
    def seed(rows): log.write_text(json.dumps({'issues':rows,'target_repo':'owner/repo'}))
    def row(n,**kw): return dict(number=n,title=f'Issue {n}',url=f'https://github.com/owner/repo/issues/{n}',status='open',chip_task_id=None,created_at='2026-10-30',**kw)
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
    close=next(b for b in blocks('modules/retract.md') if 'if ! gh issue close' in b)
    for remote,view_rc,expected_rc,expected_status in [('OPEN',0,1,'open'),('',1,1,'open'),('CLOSED',0,0,'closed')]:
        seed([dict(row(42,origin='create'),chip_task_id='offer-original')]); before=log.read_bytes()
        gh='gh() { if [[ "$2" == close ]]; then return 1; fi; printf \'%s\' '+shlex.quote(remote)+'; return '+str(view_rc)+'; }\n'
        r=run(setup+'N=42\n'+gh+close)
        assert r.returncode==expected_rc,(r.returncode,r.stderr)
        rows=json.loads(log.read_text())['issues']; assert rows[0]['status']==expected_status and rows[0]['chip_task_id']=='offer-original',rows
        if expected_rc: assert log.read_bytes()==before,'uncertain or failed close mutated state'
    print('ok workflow: failed/uncertain close leaves state byte-identical; verified lost response logs only closed status and retains cleanup token')
    seed([row(42,origin='create',chain={'chain_id':'c','position':3,'total':4}),dict(row(42,origin='create',chain={'chain_id':'c','position':3,'total':4}),url='https://github.com/foreign/repo/issues/42')])
    recut=next(b for b in blocks('modules/retract.md') if 'SURVIVOR_N' in b)
    r=run(setup+'SURVIVOR_N=42\nCHAIN_ID=c\nNEW_TITLE="Theme 2/3"\nNEW_POSITION=2\nNEW_TOTAL=3\n'+recut);assert r.returncode==0,r.stderr
    rows=json.loads(log.read_text())['issues']; assert rows[0]['title']=='Theme 2/3' and rows[0]['chain']=={'chain_id':'c','position':2,'total':3} and rows[1]['chain']['position']==3,rows
    print('ok workflow: re-cut updates survivor title and coordinates together with repository isolation')
    # First handoff emission after a declined inline offer has no token to reuse.
    seed([row(1,origin='create'),row(2,origin='update')])
    handoff_stamp=next(b for b in blocks('modules/handoff.md') if 'OFFER_TOKEN=' in b)
    r=run(setup+handoff_stamp); assert r.returncode==0,r.stderr
    rows=json.loads(log.read_text())['issues']; assert rows[0]['chip_task_id'].startswith('offer-') and rows[1]['chip_task_id'] is None
    print('ok workflow: explicit fallback handoff after decline stamps only session-filed rows')
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

    # A chain identity exists before dedup; recovery restores it without minting.
    seed([])
    init=blocks('modules/create/increment-draft.md')[0]
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
