# Trust Dialog Re-Prompting Fix

> **Always:** Check `~/.claude.json` flags when the user reports trust dialog or CLAUDE.md external includes re-prompting.
> **Ask first:** Never — diagnosis and repair are safe read/write operations on a JSON config file.
> **Never:** Delete `~/.claude.json` entirely (Claude Code recreates it with `false` defaults).

## Problem

Claude Code re-prompts for the trust dialog and CLAUDE.md external includes approval even when bypass permissions are enabled. This happens because `~/.claude.json` stores per-project flags that can reset to `false` — for example, when a new project entry is created or the file is deleted and recreated.

The three flags that must be `true` per project:

| Flag | Purpose |
|------|---------|
| `hasTrustDialogAccepted` | Suppresses the "trust this project?" dialog |
| `hasClaudeMdExternalIncludesApproved` | Suppresses re-approval of external includes in CLAUDE.md |
| `hasClaudeMdExternalIncludesWarningShown` | Suppresses the warning banner for external includes |

## Repair Script

Run this to fix flags for a specific project. Replace the `proj_key` value with the absolute path to the affected project:

```bash
python3 -c "
import json, os, sys

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

# Replace with the absolute path to your project
proj_key = '/Users/yourname/path/to/project'

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
changed = []
for flag in ['hasTrustDialogAccepted', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown']:
    if not proj.get(flag):
        proj[flag] = True
        changed.append(flag)

if changed:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f'Fixed {len(changed)} flag(s): {changed}')
else:
    print('All flags already set — no changes needed.')
"
```

To fix **all** projects at once:

```bash
python3 -c "
import json, os, sys

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

flags = ['hasTrustDialogAccepted', 'hasClaudeMdExternalIncludesApproved', 'hasClaudeMdExternalIncludesWarningShown']
total = 0
for proj_key, proj in projects.items():
    if not isinstance(proj, dict):
        print(f'Skipping invalid project entry {proj_key}: expected object, got {type(proj).__name__}.')
        continue
    for flag in flags:
        if not proj.get(flag):
            proj[flag] = True
            total += 1

if total:
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
    print(f'Fixed {total} flag(s) across {len(projects)} project(s).')
else:
    print('All flags already set across all projects — no changes needed.')
"
```

## When to Run

- **Symptom:** Claude Code prompts you to trust a project or approve external includes when it shouldn't (bypass permissions is already enabled).
- **After deleting `~/.claude.json`:** Claude Code recreates it with `false` defaults. Run the repair script after the file is recreated.
- **After cloning/moving a project:** A new project entry in `~/.claude.json` starts with `false` flags.

## Automatic Hook (Optional)

If this issue recurs frequently, add an automatic hook in `global-settings.json` to auto-repair the flags. This is not included by default because the issue is intermittent and the manual fix is fast. Create a hook script and register it under `Stop` or `PostToolUse` (these are the supported hook arrays).
