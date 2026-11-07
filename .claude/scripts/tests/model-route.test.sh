#!/usr/bin/env bash
# Tests actual routing CLI decisions across multi-attempt recovery and safety boundaries.
# catalog: tests — Multi-attempt cheap retries, diagnosed escalation, caller wiring and eligibility boundaries for model-route.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
script = root / '.claude/scripts/model-route.sh'
report = []
base = {
    'task': 'fixture-task', 'phase': 'A', 'launch_allowed': True,
    'permissions_preserved': True, 'attempts': [],
    'runtime': {'version':'2.1.312', 'model_override_forced':False},
    'models': [dict(model=m, available=True, capable=True, budget_allowed=True,
                    reserve_allowed=True, evidence='fixture/runtime.json')
               for m in ['haiku', 'sonnet', 'opus', 'fable']],
}


def attempt(n, **changes):
    row = dict(id=f'a{n}', model='haiku', outcome='failed', bug='precedence',
               signature='wrong-precedence', approach=f'approach-{n}',
               method_fingerprint=hashlib.sha256(f'normalized-method-{n}'.encode()).hexdigest(),
               method_evidence=f'fixture/method-{n}.json',
               evidence=[f'fixture/check-{n}.json'], new_evidence=[],
               remaining_blocker='precedence still fails', cost_usd=None,
               elapsed_seconds=None, review_rounds=0, ci_reruns=0)
    row.update(changes)
    return row


with tempfile.TemporaryDirectory() as tmp:
    request = Path(tmp) / 'request.json'

    def check(name, data, action, model=None, code=0):
        request.write_text(json.dumps(data), encoding="utf-8")
        started = time.monotonic()
        run = subprocess.run([str(script), '--input', str(request)], capture_output=True, text=True)
        measured = time.monotonic() - started
        result = json.loads(run.stdout)
        assert run.returncode == code, (name, run.returncode, result, run.stderr)
        assert result['action'] == action, (name, result)
        assert result['model'] == model, (name, result)
        report.append(dict(scenario=name, passed=True, action=action, model=model,
                           router_elapsed_seconds=round(measured, 6), metrics=result.get('metrics')))
        return result

    check('cheap initial worker', base, 'start', 'haiku')
    data = copy.deepcopy(base)
    data['current_model'] = 'haiku'
    data['attempts'] = [attempt(1)]
    check('one wrong answer retains cheap model', data, 'retry', 'haiku')
    # More than any customary retry cap: each attempt discovers a distinct fact.
    data['attempts'] = [attempt(n, new_evidence=[f'fixture/discovery-{n}.json']) for n in range(1, 21)]
    check('twenty useful failed attempts stay cheap', data, 'retry', 'haiku')
    data['attempts'].append(attempt(21, outcome='complete'))
    complete = check('cheap completion after useful failures', data, 'complete')
    assert complete['metrics']['failed_attempts'] == 20
    assert complete['metrics']['total_cost_usd'] is None
    assert complete['metrics']['total_elapsed_seconds'] is None
    data['attempts'] = [attempt(1), attempt(2)]
    check('loop requires diagnosis not immediate upgrade', data, 'diagnose', 'haiku', 3)
    data['diagnosis'] = dict(model='haiku', kind='stuck_bug', attempt_ids=['a1', 'a2'],
                             evidence=['fixture/diagnosis.json'], approaches_verified=True,
                             why_more_retries_unlikely='Two distinct precedence approaches failed without new evidence.')
    check('diagnosed unresolved bug steps only this phase', data, 'escalate', 'sonnet')
    other = copy.deepcopy(base)
    other['task'] = 'unrelated-task'
    other['phase'] = 'B'
    check('unrelated work remains cheap', other, 'start', 'haiku')
    data['attempts'][1]['approach'] = 'Rewording the same approach'
    data['attempts'][1]['method_fingerprint'] = data['attempts'][0]['method_fingerprint']
    check('reworded method is not a meaningfully different approach', data, 'diagnose', 'haiku', 3)
    data['attempts'] = [attempt(1), attempt(2)]
    data['diagnosis']['approaches_verified'] = False
    check('method hashes require diagnostic verification', data, 'diagnose', 'haiku', 3)
    data['diagnosis']['approaches_verified'] = True
    data['attempts'][1].pop('method_evidence')
    check('missing actual method evidence remains diagnosis', data, 'diagnose', 'haiku', 3)
    data['attempts'] = [attempt(1, poor_patch=True, review_rounds=1),
                        attempt(2, poor_patch=True, ci_reruns=1, signature='different-defect')]
    data['diagnosis']['kind'] = 'poor_patch_churn'
    check('documented repeated poor patch review and CI churn', data, 'escalate', 'sonnet')
    data['owner_model'] = 'haiku'
    check('owner pin needs owner escalation decision', data, 'owner_decision', 'haiku', 3)
    data.pop('owner_model')
    data['models'][1]['available'] = False
    check('next suitable tier skips unavailable model', data, 'escalate', 'opus')
    data['models'][2]['budget_allowed'] = False
    check('escalation never purchases a blocked tier', data, 'blocked', code=3)
    data = copy.deepcopy(base)
    data['models'][0]['available'] = False
    check('initial unavailable cheapest tier', data, 'start', 'sonnet')
    data['models'][1]['capable'] = False
    check('required context or tool support filters candidate', data, 'start', 'opus')
    data['owner_model'] = 'haiku'
    check('unavailable owner pin never substituted', data, 'blocked', code=3)
    data['owner_model'] = 'opus'
    check('explicit available owner choice preserved', data, 'start', 'opus')
    data['owner_model'] = 'fable'
    check('explicit owner choice outside unattended ladder', data, 'start', 'fable')
    data = copy.deepcopy(base)
    for row in data['models']:
        row['reserve_allowed'] = False
    check('provider reserve blocks every tier', data, 'blocked', code=3)
    data = copy.deepcopy(base)
    data['launch_allowed'] = False
    check('paused deadline or capacity gate never bypassed', data, 'blocked', code=3)
    data = copy.deepcopy(base)
    data['permissions_preserved'] = False
    check('permission change is not routing authority', data, 'blocked', code=3)
    data = copy.deepcopy(base)
    for row in data['models']:
        row.pop('capable')
    check('unknown capability is not available', data, 'blocked', code=3)
    data = copy.deepcopy(base)
    result = check('unknown local checks cannot submit', data, 'start', 'haiku')
    assert result['submission_allowed'] is False
    data['submission'] = dict(local_checks_passed=True, distinct_changes=True, batched=True)
    result = check('checked changed batched patch can submit', data, 'start', 'haiku')
    assert result['submission_allowed'] is True
    data['submission']['distinct_changes'] = False
    result = check('unchanged push blocked while local retries allowed', data, 'start', 'haiku')
    assert result['submission_allowed'] is False
    data['current_model'] = 'haiku'
    data['attempts'] = [attempt(1, cost_usd=0.02, elapsed_seconds=4), attempt(2)]
    result = check('partial cost not a complete spend total', data, 'diagnose', 'haiku', 3)
    assert result['metrics']['known_cost_usd'] == 0.02
    assert result['metrics']['total_cost_usd'] is None
    data['attempts'][1].update(cost_usd=0.03, elapsed_seconds=6)
    result = check('actual recorded totals retained', data, 'diagnose', 'haiku', 3)
    assert abs(result['metrics']['total_cost_usd'] - 0.05) < 1e-10
    assert result['metrics']['total_elapsed_seconds'] == 10
    data['attempts'][1]['model'] = 'sonnet'
    check('history model mismatch fails validation', data, 'invalid', code=2)
    data['current_model'] = 'sonnet'
    check('fresh higher tier does not inherit cheap-tier loop', data, 'retry', 'sonnet')
    data['attempts'][1]['cost_usd'] = '0'
    check('string spend not silently coerced to zero', data, 'invalid', code=2)
    data = copy.deepcopy(base)
    data['current_model'] = 'haiku'
    data['attempts'] = [attempt(1, outcome='progress')]
    check('asserted progress requires new evidence', data, 'invalid', code=2)
    data['attempts'][0]['new_evidence'] = ['fixture/new-cause.json']
    check('documented progress retains cheap model', data, 'retry', 'haiku')
    data['attempts'][0]['cost_usd'] = float('nan')
    check('nonfinite spend never becomes known', data, 'invalid', code=2)
    data = copy.deepcopy(base)
    data['current_model'] = 'opus'
    check('old premium default is not retry history', data, 'invalid', code=2)
    data['current_model'] = 'fable'
    data['attempts'] = [attempt(1, model='fable')]
    check('owner-only tier never loses its explicit pin', data, 'blocked', code=3)
    data['attempts'][0]['cost_usd'] = 10 ** 1000
    check('overflowing JSON integer returns structured invalid', data, 'invalid', code=2)
    data = copy.deepcopy(base)
    data['runtime']['version'] = '2.1.250'
    check('legacy runtime cannot override recorded cheap route', data, 'blocked', code=3)
    data['runtime']['version'] = '2.1.312'
    data['runtime']['model_override_forced'] = True
    check('forced runtime model choice is not silently cleared', data, 'blocked', code=3)
    data.pop('runtime')
    check('unknown runtime precedence cannot launch', data, 'blocked', code=3)
    data = copy.deepcopy(base)
    data['current_model'] = 'haiku'
    data['attempts'] = [dict(id='wait-1', model='haiku', outcome='waiting',
                             evidence=['fixture/pending-review.json'], next_action='await changed reviewer state')]
    check('truthful unchanged waiting does not invoke model', data, 'wait', code=3)
    data['wake_evidence'] = ['fixture/new-review.json']
    check('changed evidence resumes waiting task on cheap model', data, 'retry', 'haiku')
    data['attempts'] = [dict(id='exhaust-1', model='haiku', outcome='exhaustion',
                             evidence=['fixture/valid-handoff.json'], next_action='resume preserved investigation')]
    check('exhaustion is not a quality failure', data, 'retry', 'haiku')
    # The caller examples must still feed all three phase call sites through routing.
    skill = (root / '.claude/skills/subagent/SKILL.md').read_text(encoding="utf-8")
    assert skill.count('`model: ROUTED_MODEL`') == 3
    assert 'model-route.sh' in skill and 'failed write' in skill
    pmm = (root / '.claude/skills/pr-monitor-and-manage/references/pmm-act.md').read_text(encoding="utf-8")
    forgotten = (root / '.claude/skills/pm-forgotten-pr/SKILL.md').read_text(encoding="utf-8")
    assert 'model: ROUTED_MODEL' in pmm and 'task-model-route-dispatch' in pmm
    assert 'model: ROUTED_MODEL' in forgotten and 'task-model-route-dispatch' in forgotten
    reference = (root / '.claude/reference/task-model-routing.md').read_text(encoding='utf-8')
    handoff_block = reference.split('# routed-handoff-write\n', 1)[1].split('\n```', 1)[0]
    submission_block = reference.split('# model-route-submission\n', 1)[1].split('\n```', 1)[0]
    normalize = lambda content: '\n'.join(line.strip() for line in content.splitlines())
    phase_a = (root / '.claude/agents/phase-a-fixer.md').read_text(encoding='utf-8')
    phase_b = (root / '.claude/agents/phase-b-reviewer.md').read_text(encoding='utf-8')
    assert normalize(handoff_block) in normalize(phase_a)
    assert normalize(handoff_block) in normalize(skill)
    assert normalize(submission_block) in normalize(phase_a)
    assert normalize(submission_block) in normalize(phase_b)
    for role in ['phase-a-fixer', 'phase-b-reviewer', 'phase-c-merger', 'pm-worker', 'researcher']:
        agent = (root / '.claude/agents' / (role + '.md')).read_text(encoding="utf-8")
        assert '\nmodel: haiku\n' in agent

payload = dict(kind='deterministic_router_fixtures', model_quality=None,
               model_spend_usd=None, scenarios=report)
if os.environ.get('MODEL_ROUTE_TRIAL_REPORT'):
    Path(os.environ['MODEL_ROUTE_TRIAL_REPORT']).write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
print(f'{len(report)} routing scenarios passed; simulated attempt histories, no inference/savings claim.')
PY

# Exercise the actual dispatch block with the real locked state writers.
source "$ROOT/.claude/scripts/tests/lib/skill-bash.sh"
ROUTE_TMP=$(mktemp -d)
trap 'rm -rf "$ROUTE_TMP"' EXIT
export HOME="$ROUTE_TMP/home"
mkdir -p "$HOME"
export OWNER_REPO=fixture/router
export MODEL_ROUTE_SH="$ROOT/.claude/scripts/model-route.sh"
export SESSION_STATE_SH="$ROOT/.claude/scripts/session-state.sh"
export HANDOFF_STATE_SH="$ROOT/.claude/scripts/handoff-state.sh"
export MODEL_ROUTE_REQUEST="$ROUTE_TMP/request.json"
unset PR_NUMBER
extract_skill_bash "$ROOT/.claude/reference/task-model-routing.md" task-model-route-dispatch > "$ROUTE_TMP/dispatch.sh"
cat > "$MODEL_ROUTE_REQUEST" <<'JSON'
{"task":"issue-123","phase":"A","launch_allowed":true,"permissions_preserved":true,"runtime":{"version":"2.1.312","model_override_forced":false},"attempts":[],"models":[{"model":"haiku","available":true,"capable":true,"budget_allowed":true,"reserve_allowed":true,"evidence":"fixture/runtime.json"}]}
JSON
printf '\nprintf "%%s" "$ROUTED_MODEL"\n' >> "$ROUTE_TMP/dispatch.sh"
selected=$(bash "$ROUTE_TMP/dispatch.sh")
[[ "$selected" == haiku ]]
saved=$("$SESSION_STATE_SH" --repo "$OWNER_REPO" --get-json '.repos["fixture/router"].tasks["issue-123"].model_routing.A.decision.model')
[[ "$saved" == '"haiku"' || "$saved" == haiku ]]

# Same task IDs in different repositories must never share routing history.
jq '.owner_model="sonnet" | .models += [{"model":"sonnet","available":true,"capable":true,"budget_allowed":true,"reserve_allowed":true,"evidence":"fixture/runtime.json"}]' "$MODEL_ROUTE_REQUEST" > "$ROUTE_TMP/other-repo.json"
selected=$(OWNER_REPO=Fixture/Other MODEL_ROUTE_REQUEST="$ROUTE_TMP/other-repo.json" bash "$ROUTE_TMP/dispatch.sh")
[[ "$selected" == sonnet ]]
"$SESSION_STATE_SH" --repo "$OWNER_REPO" --get-json '.repos["fixture/router"].tasks["issue-123"].model_routing.A.decision.model' | jq -e '. == "haiku"' >/dev/null
"$SESSION_STATE_SH" --repo "$OWNER_REPO" --get-json '.repos["fixture/other"].tasks["issue-123"].model_routing.A.decision.model' | jq -e '. == "sonnet"' >/dev/null
"$SESSION_STATE_SH" --repo "$OWNER_REPO" --get-json '.tasks' | jq -e '. == null' >/dev/null
selected=$(OWNER_REPO=Fixture/Router bash "$ROUTE_TMP/dispatch.sh")
[[ "$selected" == haiku ]]
"$SESSION_STATE_SH" --repo "$OWNER_REPO" --get-json '.repos["Fixture/Router"]' | jq -e '. == null' >/dev/null
rc=0
SESSION_STATE_SH=/usr/bin/false bash "$ROUTE_TMP/dispatch.sh" > "$ROUTE_TMP/failed-session-write.out" 2>/dev/null || rc=$?
[[ "$rc" == 4 && ! -s "$ROUTE_TMP/failed-session-write.out" ]]

export PR_NUMBER=123
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --init "$PR_NUMBER" '{"unknown_future":{"keep":true},"model_routing":{"old-task":{"B":{"sentinel":true}}}}' >/dev/null
selected=$(bash "$ROUTE_TMP/dispatch.sh")
[[ "$selected" == haiku ]]
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.model_routing["old-task"].B.sentinel and .model_routing["issue-123"].A.decision.model == "haiku"' >/dev/null
rc=0
HANDOFF_STATE_SH=/usr/bin/false bash "$ROUTE_TMP/dispatch.sh" > "$ROUTE_TMP/failed-write.out" 2>/dev/null || rc=$?
[[ "$rc" == 4 && ! -s "$ROUTE_TMP/failed-write.out" ]]
jq '.launch_allowed=false' "$MODEL_ROUTE_REQUEST" > "$ROUTE_TMP/blocked.json"
rc=0
MODEL_ROUTE_REQUEST="$ROUTE_TMP/blocked.json" bash "$ROUTE_TMP/dispatch.sh" > "$ROUTE_TMP/blocked.out" || rc=$?
[[ "$rc" == 3 && ! -s "$ROUTE_TMP/blocked.out" ]]
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.model_routing["issue-123"].A.decision.action == "blocked" and .model_routing["issue-123"].A.decision.model == null' >/dev/null
rc=0
PR_NUMBER=999 bash "$ROUTE_TMP/dispatch.sh" > "$ROUTE_TMP/missing.out" 2>/dev/null || rc=$?
[[ "$rc" == 4 && ! -s "$ROUTE_TMP/missing.out" ]]
echo 'Real dispatch block: session and handoff records persisted, other phase retained, blocked/write-failure/missing-record launches refused.'

# The actual handoff-write block retains old completed tasks while seeding a new goal.
extract_skill_bash "$ROOT/.claude/reference/task-model-routing.md" routed-handoff-write > "$ROUTE_TMP/handoff-write.sh"
export HANDOFF_JSON='{"phase_completed":"A","notes":"fixture metadata"}'
jq '.current_model="haiku" | .attempts=[{"id":"done-1","model":"haiku","outcome":"complete","evidence":["fixture/passed.json"]}]' "$MODEL_ROUTE_REQUEST" > "$ROUTE_TMP/completed-request.json"
route_decision=$("$MODEL_ROUTE_SH" --input "$ROUTE_TMP/completed-request.json")
export MODEL_ROUTE_RECORD
MODEL_ROUTE_RECORD=$(jq -cn --slurpfile request "$ROUTE_TMP/completed-request.json" --argjson decision "$route_decision" '{request:$request[0],decision:$decision}')
bash "$ROUTE_TMP/handoff-write.sh"
jq '.task="pr-123-new-findings" | del(.current_model) | .attempts=[]' "$MODEL_ROUTE_REQUEST" > "$ROUTE_TMP/new-task-request.json"
route_decision=$("$MODEL_ROUTE_SH" --input "$ROUTE_TMP/new-task-request.json")
MODEL_ROUTE_RECORD=$(jq -cn --slurpfile request "$ROUTE_TMP/new-task-request.json" --argjson decision "$route_decision" '{request:$request[0],decision:$decision}')
bash "$ROUTE_TMP/handoff-write.sh"
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.model_routing["issue-123"].A.decision.action == "complete" and .model_routing["pr-123-new-findings"].A.decision.action == "start" and .model_routing["old-task"].B.sentinel and .unknown_future.keep' >/dev/null

# The same tested post-edit guard is embedded in both fixer agents.
mkdir -p "$HOME/.claude/scripts"
ln -s "$MODEL_ROUTE_SH" "$HOME/.claude/scripts/model-route.sh"
ln -s "$ROOT/.claude/scripts/lib" "$HOME/.claude/scripts/lib"
extract_skill_bash "$ROOT/.claude/reference/task-model-routing.md" model-route-submission > "$ROUTE_TMP/submission.sh"
printf '\nprintf "allowed"\n' >> "$ROUTE_TMP/submission.sh"
rc=0
bash "$ROUTE_TMP/submission.sh" > "$ROUTE_TMP/submission.out" || rc=$?
[[ "$rc" == 5 && ! -s "$ROUTE_TMP/submission.out" ]]
jq '.submission={local_checks_passed:true,distinct_changes:true,batched:true}' "$MODEL_ROUTE_REQUEST" > "$ROUTE_TMP/checked-request.json"
[[ "$(MODEL_ROUTE_REQUEST="$ROUTE_TMP/checked-request.json" bash "$ROUTE_TMP/submission.sh")" == allowed ]]
echo 'Real handoff/submit blocks: completed task retained, new task seeded, unknown fields kept, post-edit push guard enforced.'

# Execute the actual Phase A commit/submission block with a denied submission.
# A local commit must survive, pushes must not run, and recovery must be reached.
python3 - "$ROOT" "$ROUTE_TMP/fixer-submit.sh" <<'PYFIX'
from pathlib import Path
import sys
text = (Path(sys.argv[1]) / '.claude/agents/phase-a-fixer.md').read_text()
block = text.split('# Replace the placeholder list below', 1)[1].split('\n```', 1)[0]
Path(sys.argv[2]).write_text("git() { case \"$1\" in diff) return 1;; commit) echo commit >> \"$ROUTE_TMP/events\";; push) echo push >> \"$ROUTE_TMP/events\";; esac; }\n# Replace the placeholder list below" + block + '\n[[ "$SUBMISSION_BLOCKED" == true ]] || exit 1\nprintf recovery\n')
PYFIX
export ROUTE_TMP
[[ "$(bash "$ROUTE_TMP/fixer-submit.sh" 2>"$ROUTE_TMP/fixer-submit.err")" == recovery ]]
[[ "$(cat "$ROUTE_TMP/events")" == commit ]]
echo 'Actual Phase A refusal: local commit retained, push suppressed, recovery path reached.'

# A blocked submission writes recovery state without a completed phase marker.
HANDOFF_JSON='{"phase_completed":"","head_sha":"unpushed-fixture","outcome":"blocked","notes":"submission refused"}' bash "$ROUTE_TMP/handoff-write.sh"
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.phase_completed == "" and .outcome == "blocked" and .head_sha == "unpushed-fixture" and .model_routing["pr-123-new-findings"].A.decision.action == "start"' >/dev/null
echo 'Blocked recovery handoff: unpushed SHA/routing preserved, completion marker cleared.'
