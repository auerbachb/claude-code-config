#!/bin/bash
# Fix trust flags for ALL projects in ~/.claude.json.
# Usage: bash .claude/scripts/repair-trust-all.sh
# See .claude/rules/trust-dialog-fix.md for details.

set -euo pipefail

python3 -c "
import json, os, sys, tempfile

path = os.path.expanduser('~/.claude.json')

try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    print(f'Config not found: {path}')
    print('Open Claude Code once to recreate it, then re-run this fix.')
    sys.exit(1)
except json.JSONDecodeError as e:
    print(f'Invalid JSON in {path}: {e}')
    print('Repair or restore ~/.claude.json, then re-run this fix.')
    sys.exit(1)

if not isinstance(data, dict):
    print('Invalid ~/.claude.json: root must be an object.')
    sys.exit(1)

if 'projects' not in data:
    projects = {}
else:
    projects = data['projects']
    if not isinstance(projects, dict):
        print('Invalid ~/.claude.json: \"projects\" must be an object.')
        sys.exit(1)

flags = ['hasTrustDialogAccepted', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown']
total = 0
affected = set()
for proj_key, proj in projects.items():
    if not isinstance(proj, dict):
        print(f'Skipping invalid project entry {proj_key}: expected object, got {type(proj).__name__}.')
        continue
    for flag in flags:
        if not proj.get(flag):
            proj[flag] = True
            total += 1
            affected.add(proj_key)

if total:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try: os.unlink(tmp)
        except OSError: pass
        raise
    print(f'Fixed {total} flag(s) across {len(affected)} project(s).')
else:
    print('All flags already set across all projects — no changes needed.')
"
