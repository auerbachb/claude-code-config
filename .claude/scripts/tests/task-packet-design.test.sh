#!/usr/bin/env bash
# catalog: tests — Offline task-packet design walkthrough: overlap, resume, source drift, unknown evidence and context bounds
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
python3 - "$ROOT" <<'PY'
"""Fixture-only design oracle. No production assembler or operational workflow."""
import copy
import hashlib
import json
import posixpath
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
fixture = json.loads((root / '.claude/scripts/tests/fixtures/task-packets/walkthrough.json').read_text(encoding="utf-8"))
base = fixture['base']
checks = 0


def verify(condition, message):
    global checks
    assert condition, message
    checks += 1


def digest(body):
    return hashlib.sha256(body.encode('utf-8')).hexdigest()


def merge(target, changes):
    for key, value in changes.items():
        if isinstance(value, dict):
            merge(target[key], value)
        else:
            target[key] = value
    return target


def surfaces(paths):
    if paths is None:
        return None
    normalized = [posixpath.normpath(p) for p in paths]
    if any(p == '..' or p.startswith('../') or p.startswith('/') for p in normalized):
        return None
    return {'rule-corpus' if p == 'CLAUDE.md' or p.startswith('.claude/rules/') else p for p in normalized}


def overlaps(left, right):
    a, b = surfaces(left), surfaces(right)
    return None if a is None or b is None else bool(a & b)


def evidence_validity(row, live):
    return ('current' if row.get('pointer') and row.get('revision')
            and row.get('repo') == live['repo'] and row.get('head') == live['head']
            else 'unknown')


def index_for_fixture(source):
    # Demonstrates the proposed projection only. Runtime adapters must retrieve
    # and validate canonical sources/ownership; this function does neither.
    packet = {
        'identity': {k: source[k] for k in ('repo', 'issue', 'worktree', 'branch', 'head')},
        'spec': {'pointer': source['spec']['url'], 'revision': source['spec']['revision'],
                 'body_sha256': digest(source['spec']['body']),
                 'ac_count': len(re.findall(r'^[ \t]*-[ \t]+\[[ xX]\]', source['spec']['body'], re.M)),
                 'load_complete_before_act': True},
        'ownership': copy.deepcopy(source['claim']),
        'phase': source['phase'],
        'active_module': source['modules'][source['phase']],
        'sources': copy.deepcopy(source['sources']),
        'touchpoints': copy.deepcopy(source['touchpoints']),
        'commands': copy.deepcopy(source['commands']),
        'evidence': [dict(row, validity=evidence_validity(row, source)) for row in source['evidence']],
        'recovery': copy.deepcopy(source['recovery']),
        'gate_pointers': copy.deepcopy(source['gate_pointers']),
        'needs_detail': [],
    }
    for key, limit in [('touchpoints', fixture['max_touchpoints']),
                       ('commands', fixture['max_commands']), ('evidence', fixture['max_evidence'])]:
        if packet[key] is None or len(packet[key]) > limit:
            count = len(packet[key]) if packet[key] is not None else None
            packet[key] = {'count': count, 'pointer': 'fixture://canonical/' + key}
            packet['needs_detail'].append(key)
    def size(value):
        return len(json.dumps(value, ensure_ascii=False).encode('utf-8'))
    # Byte overflow can occur below any list-count cap. Replace complete detail
    # sections by pointers, largest first; never silently cut their contents.
    for key in sorted(('touchpoints', 'commands', 'evidence', 'recovery'),
                      key=lambda key: size(packet[key]), reverse=True):
        if size(packet) <= fixture['index_bytes']:
            break
        if key == 'recovery':
            packet[key] = {'pointer': source['recovery']['pointer']}
        elif isinstance(packet[key], list):
            packet[key] = {'count': len(packet[key]), 'pointer': 'fixture://canonical/' + key}
        else:
            continue
        if key not in packet['needs_detail']:
            packet['needs_detail'].append(key)
    if size(packet) > fixture['index_bytes']:
        raise ValueError('minimal identity/source index exceeds bound; retrieve canonical task directly')
    return packet


def freshness(packet, live, age=0):
    if live['claim']['status'] != 'mine':
        return 'unknown'
    if age > fixture['max_age_seconds']:
        return 'stale'
    if any(packet['identity'][k] != live[k] for k in packet['identity']):
        return 'stale'
    if packet['phase'] != live['phase'] or packet['active_module'] != live['modules'][live['phase']]:
        return 'stale'
    if any(packet['ownership'][k] != live['claim'][k] for k in ('holder', 'author', 'marker_id', 'created_at')):
        return 'stale'
    if packet['sources'] != live['sources'] or packet['spec']['revision'] != live['spec']['revision']:
        return 'stale'
    if packet['spec']['body_sha256'] != digest(live['spec']['body']):
        return 'stale'
    return 'current'


packet = index_for_fixture(base)
for case in fixture['pairs']:
    verify(overlaps(case['left'], case['right']) == case['expected_overlap'], case['name'])
for case in fixture['freshness_cases']:
    live = merge(copy.deepcopy(base), case['change'])
    verify(freshness(packet, live, case.get('age_seconds', 0)) == case['expected'], case['name'])
verify(packet['spec']['ac_count'] == 2, 'all acceptance criteria counted')
verify('body' not in packet['spec'], 'full body remains at canonical pointer')
verify(packet['active_module'] == 'fixture://phase-a', 'active module only')
verify('fixture://unrelated' not in json.dumps(packet), 'unrelated modules not loaded')
verify('fixture://phase-b' not in json.dumps(packet), 'future phase not preloaded')
verify(packet['gate_pointers'] == base['gate_pointers'], 'independent gates retained as pointers')
verify('merge_ready' not in packet, 'packet cannot certify a merge')
verify(packet['ownership']['holder'] == base['claim']['holder'], 'exact holder retained')

resumed = copy.deepcopy(base)
resumed['head'] = 'b' * 40
resumed['phase'] = 'B'
resumed['sources']['handoff'] = 'handoff101-v2'
resumed['sources']['module'] = 'module-B-v2'
verify(freshness(packet, resumed) == 'stale', 'interrupted packet invalidated at new head/phase')
rebuilt = index_for_fixture(resumed)
verify(rebuilt['recovery'] == base['recovery'], 'cheaper replacement retains discoveries and next action')
verify(rebuilt['evidence'][0]['validity'] == 'unknown', 'old-head check cannot certify new head')
verify(rebuilt['active_module'] == 'fixture://phase-b', 'resume loads current phase only')
verify('fixture://phase-a' not in json.dumps(rebuilt), 'old module not reloaded')
verify(rebuilt['ownership'] == base['claim'], 'resume packet never acquires or transfers ownership')
missing = copy.deepcopy(base['evidence'][0])
missing['pointer'] = None
verify(evidence_validity(missing, base) == 'unknown', 'missing evidence is unknown')
missing['pointer'] = 'fixture://unreadable'
missing['revision'] = None
verify(evidence_validity(missing, base) == 'unknown', 'unreadable revision is unknown')
missing.update(revision='check-v1', repo='fixture/other')
verify(evidence_validity(missing, base) == 'unknown', 'wrong-repo evidence is unknown')
verify(packet['commands'][0]['cwd'] == base['worktree'], 'verification command preserves working directory')
verify(packet['commands'][0]['result_pointer'] == 'fixture://evidence/check-1', 'verification command retains result pointer')
indented = copy.deepcopy(base)
indented['spec']['body'] += '\n  - [ ] Indented criterion.\n\t- [x] Tab-indented criterion.'
verify(index_for_fixture(indented)['spec']['ac_count'] == 4, 'indented acceptance criteria counted')
under_cap = copy.deepcopy(base)
under_cap['commands'][0]['command'] = 'é' * 6000
bounded_command = index_for_fixture(under_cap)
verify(bounded_command['commands']['count'] == 1 and 'commands' in bounded_command['needs_detail'], 'under-count-limit byte overflow uses complete detail pointer')
under_cap = copy.deepcopy(base)
under_cap['touchpoints'] = ['src/' + 'é' * 6000]
verify('touchpoints' in index_for_fixture(under_cap)['needs_detail'], 'oversized single touchpoint becomes pointer')
large = copy.deepcopy(base)
large['spec']['body'] += '\n' + '\n'.join('- [ ] Criterion ' + str(i) for i in range(1000))
bounded = index_for_fixture(large)
verify(bounded['spec']['ac_count'] == 1002, 'large spec loses no acceptance criteria')
verify(len(json.dumps(bounded).encode()) <= fixture['index_bytes'], 'canonical spec pointer keeps bounded index')
large['touchpoints'] = ['src/file-' + str(i) for i in range(17)]
large['commands'] = [dict(command='check ' + str(i), cwd='/fixture', result_pointer=None) for i in range(9)]
large['evidence'] = [dict(base['evidence'][0], id='e' + str(i)) for i in range(9)]
bounded = index_for_fixture(large)
verify(set(bounded['needs_detail']) == {'touchpoints', 'commands', 'evidence'}, 'overflow requires on-demand detail')
verify(bounded['touchpoints']['count'] == 17, 'overflow is not silently sliced')
large['recovery']['discoveries'] = ['é' * 6000]
bounded = index_for_fixture(large)
verify(bounded['recovery'] == {'pointer': base['recovery']['pointer']}, 'oversized recovery keeps canonical source')
large['worktree'] = '/fixture/' + 'é' * 5000
try:
    index_for_fixture(large)
except ValueError:
    verify(True, 'UTF-8 byte limit refuses oversized identity')
else:
    verify(False, 'UTF-8 byte limit not enforced')
changed = copy.deepcopy(base)
changed['spec']['body'] += '\n- [ ] New owner criterion.'
verify(freshness(packet, changed) == 'stale', 'body hash detects unadvertised AC change')
print(f'{checks} task-packet design checks passed (offline fixtures; no deployed assembler/coordination claim).')
PY
