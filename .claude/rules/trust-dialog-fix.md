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

Worktrees are the primary cause — each gets a unique path registered as a new project with `false` defaults. The `claude-code-config` repo is especially affected because global symlinks point back into it, triggering "external includes" detection.

## Manual Repair

Run from the repo root:

- **Single project:** `bash .claude/scripts/repair-trust-single.sh /path/to/project`
- **All projects:** `bash .claude/scripts/repair-trust-all.sh`

Both use atomic writes (`tempfile` + `os.replace`) for safety.

## Automatic Hook

The `trust-flag-repair.sh` Stop hook (`.claude/hooks/trust-flag-repair.sh`, registered in `global-settings.json`) repairs all flags after every agent response. It cannot prevent the initial prompt on brand-new worktrees — the project entry doesn't exist yet. The hook repairs it after the first response.
