#!/usr/bin/env bash
# Tests actual routing CLI decisions across multi-attempt recovery and safety boundaries.
# catalog: tests — Multi-attempt cheap retries, diagnosed escalation, caller wiring and eligibility boundaries for model-route.sh
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
import copy
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
    'models': [dict(model=m, available=True, capable=True, budget_allowed=True,
                    reserve_allowed=True, evidence='fixture/runtime.json')
               for m in ['haiku', 'sonnet', 'opus', 'fable']],
}


def attempt(n, **changes):
    row = dict(id=f'a{n}', model='haiku', outcome='failed', bug='precedence',
               signature='wrong-precedence', approach=f'approach-{n}',
               evidence=[f'fixture/check-{n}.json'], new_evidence=[],
               remaining_blocker='precedence still fails', cost_usd=None,
               elapsed_seconds=None, review_rounds=0, ci_reruns=0)
    row.update(changes)
    return row


with tempfile.TemporaryDirectory() as tmp:
    request = Path(tmp) / 'request.json'

    def check(name, data, action, model=None, code=0):
        request.write_text(json.dumps(data))
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
                             evidence=['fixture/diagnosis.json'],
                             why_more_retries_unlikely='Two distinct precedence approaches failed without new evidence.')
    check('diagnosed unresolved bug steps only this phase', data, 'escalate', 'sonnet')
    other = copy.deepcopy(base)
    other['task'] = 'unrelated-task'
    other['phase'] = 'B'
    check('unrelated work remains cheap', other, 'start', 'haiku')
    data['attempts'][1]['approach'] = data['attempts'][0]['approach']
    check('identical command repetition not meaningful diagnosis', data, 'diagnose', 'haiku', 3)
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
    # The caller examples must still feed all three phase call sites through routing.
    skill = (root / '.claude/skills/subagent/SKILL.md').read_text()
    assert skill.count('`model: ROUTED_MODEL`') == 3
    assert 'model-route.sh' in skill and 'failed write' in skill
    pmm = (root / '.claude/skills/pr-monitor-and-manage/references/pmm-act.md').read_text()
    forgotten = (root / '.claude/skills/pm-forgotten-pr/SKILL.md').read_text()
    assert 'model: ROUTED_MODEL' in pmm and 'task-model-route-dispatch' in pmm
    assert 'model: ROUTED_MODEL' in forgotten and 'task-model-route-dispatch' in forgotten
    for role in ['phase-a-fixer', 'phase-b-reviewer', 'phase-c-merger', 'pm-worker', 'researcher']:
        agent = (root / '.claude/agents' / (role + '.md')).read_text()
        assert '\nmodel: haiku\n' in agent

payload = dict(kind='deterministic_router_fixtures', model_quality=None,
               model_spend_usd=None, scenarios=report)
if os.environ.get('MODEL_ROUTE_TRIAL_REPORT'):
    Path(os.environ['MODEL_ROUTE_TRIAL_REPORT']).write_text(json.dumps(payload, indent=2) + '\n')
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
{"task":"issue-123","phase":"A","launch_allowed":true,"permissions_preserved":true,"attempts":[],"models":[{"model":"haiku","available":true,"capable":true,"budget_allowed":true,"reserve_allowed":true,"evidence":"fixture/runtime.json"}]}
JSON
printf '\nprintf "%%s" "$ROUTED_MODEL"\n' >> "$ROUTE_TMP/dispatch.sh"
selected=$(bash "$ROUTE_TMP/dispatch.sh")
[[ "$selected" == haiku ]]
saved=$("$SESSION_STATE_SH" --repo "$OWNER_REPO" --get '.tasks["issue-123"].model_routing.A.decision.model')
[[ "$saved" == '"haiku"' || "$saved" == haiku ]]

export PR_NUMBER=123
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --init "$PR_NUMBER" '{"model_routing":{"B":{"sentinel":true}}}' >/dev/null
selected=$(bash "$ROUTE_TMP/dispatch.sh")
[[ "$selected" == haiku ]]
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.model_routing.B.sentinel and .model_routing.A.decision.model == "haiku"' >/dev/null
rc=0
HANDOFF_STATE_SH=/usr/bin/false bash "$ROUTE_TMP/dispatch.sh" > "$ROUTE_TMP/failed-write.out" 2>/dev/null || rc=$?
[[ "$rc" == 4 && ! -s "$ROUTE_TMP/failed-write.out" ]]
jq '.launch_allowed=false' "$MODEL_ROUTE_REQUEST" > "$ROUTE_TMP/blocked.json"
rc=0
MODEL_ROUTE_REQUEST="$ROUTE_TMP/blocked.json" bash "$ROUTE_TMP/dispatch.sh" > "$ROUTE_TMP/blocked.out" || rc=$?
[[ "$rc" == 3 && ! -s "$ROUTE_TMP/blocked.out" ]]
"$HANDOFF_STATE_SH" --owner-repo "$OWNER_REPO" --get "$PR_NUMBER" | jq -e '.model_routing.A.decision.action == "blocked" and .model_routing.A.decision.model == null' >/dev/null
rc=0
PR_NUMBER=999 bash "$ROUTE_TMP/dispatch.sh" > "$ROUTE_TMP/missing.out" 2>/dev/null || rc=$?
[[ "$rc" == 4 && ! -s "$ROUTE_TMP/missing.out" ]]
echo 'Real dispatch block: session and handoff records persisted, other phase retained, blocked/write-failure/missing-record launches refused.'
