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

## Worktree Root Cause

Every worktree gets its own absolute path (e.g., `/Users/you/repo/.claude/worktrees/my-worktree/`), and Claude Code registers this as a separate project in `~/.claude.json`. New project entries start with all trust flags set to `false`, triggering the trust dialog and external includes approval prompts.

This is especially problematic for the `claude-code-config` repo because it is the global config source — `~/.claude/CLAUDE.md` and `~/.claude/rules` are symlinks pointing **into** this repo. From a worktree's perspective, those symlinks resolve to paths outside the worktree directory, so Claude Code treats them as "external includes." Other repos using worktrees don't have this problem because their global symlinks don't point back into themselves.

See the README troubleshooting section (Cause 3) for the full topology explanation and upstream issue links.

**Recommended mitigation:** The `trust-flag-repair.sh` Stop hook (see "Automatic Hook" below) repairs flags after every agent response, preventing re-prompting on subsequent operations within a session.

## When to Run

- **Symptom:** Claude Code prompts you to trust a project or approve external includes when it shouldn't (bypass permissions is already enabled).
- **After deleting `~/.claude.json`:** Claude Code recreates it with `false` defaults. Run the repair script after the file is recreated.
- **After cloning/moving a project:** A new project entry in `~/.claude.json` starts with `false` flags.

## Automatic Hook

The `trust-flag-repair.sh` script runs as a `Stop` hook after every agent response. It repairs all trust flags across all projects in `~/.claude.json`, preventing re-prompting on subsequent operations within a session.

- **Script:** `.claude/hooks/trust-flag-repair.sh`
- **Registered in:** `global-settings.json` under `hooks.Stop`
- **Behavior:** Idempotent — safe to run repeatedly. Exits silently when all flags are already set. Handles missing `~/.claude.json` gracefully.
- **Limitation:** Cannot prevent the initial trust prompt when a brand-new worktree is created for the first time (the project entry doesn't exist yet). The hook repairs it after the first response, so subsequent operations in that session won't re-prompt.

The manual repair scripts above remain useful for debugging and one-off fixes (e.g., after deleting `~/.claude.json`).
