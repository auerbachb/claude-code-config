#!/bin/bash
# Fix trust flags for a single project in ~/.claude.json.
# Usage: bash .claude/scripts/repair-trust-single.sh /absolute/path/to/project
# See .claude/rules/trust-dialog-fix.md for details.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <absolute-project-path>"
  echo "Example: $0 /Users/you/repos/my-project"
  exit 1
fi

proj_key="$1"

python3 -c "
import json, os, sys, tempfile

proj_key = sys.argv[1]
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

projects = data.get('projects') or {}
if not isinstance(projects, dict):
    print('Invalid ~/.claude.json: \"projects\" must be an object.')
    sys.exit(1)

if proj_key not in projects:
    print(f'Project key not found: {proj_key}')
    print('Available projects:')
    for k in projects:
        print(f'  {k}')
    sys.exit(1)

proj = projects[proj_key]
if not isinstance(proj, dict):
    print(f'Invalid project entry for {proj_key}: expected object, got {type(proj).__name__}.')
    sys.exit(1)

flags = ['hasTrustDialogAccepted', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown']
changed = []
for flag in flags:
    if not proj.get(flag):
        proj[flag] = True
        changed.append(flag)

if changed:
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
    print(f'Fixed {len(changed)} flag(s): {changed}')
else:
    print('All flags already set — no changes needed.')
" "$proj_key"
