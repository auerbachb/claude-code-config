# Trust Dialog Re-Prompting Fix

> **Always:** Check `~/.claude.json` flags when the user reports trust dialog re-prompting.
> **Ask first:** Never — diagnosis and repair are safe read/write operations on a JSON config file.
> **Never:** Delete `~/.claude.json` entirely (Claude Code recreates it with `false` defaults).

## Problem

Claude Code re-prompts for trust dialog and external includes approval because `~/.claude.json` stores per-project flags that reset to `false` on new project entries (e.g., new worktrees).

Three flags must be `true` per project:

| Flag | Purpose |
|------|---------|
| `hasTrustDialogAccepted` | Suppresses trust dialog |
| `hasClaudeMdExternalIncludesApproved` | Suppresses external includes re-approval |
| `hasClaudeMdExternalIncludesWarningShown` | Suppresses external includes warning |

New worktree paths register as new projects with `false` defaults; this repo's global symlinks amplify it via external-includes detection.

> **Related:** the same symlinks also caused CLAUDE.md + rules double-loading, fixed separately via project-local `claudeMdExcludes` — `.claude/reference/double-loading-fix.md`.

## Manual Repair

Run from the repo root:

- **Single project:** `bash .claude/scripts/repair-trust-single.sh /path/to/project`
- **All projects:** `bash .claude/scripts/repair-trust-all.sh`

Both use atomic writes (`tempfile` + `os.replace`) for safety.

## Automatic Hook

The `trust-flag-repair.sh` Stop hook (`global-settings.json`) repairs all flags after every response; brand-new worktrees still see the first prompt (no project entry yet), repaired after the first response.
