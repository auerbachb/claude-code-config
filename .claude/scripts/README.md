# .claude/scripts/

Manually-invoked utility scripts. Run these from the command line when needed.

| Script | Purpose |
|--------|---------|
| `repair-trust-single.sh <absolute-project-path>` | Fix trust flags for one project in `~/.claude.json` |
| `repair-trust-all.sh` | Fix trust flags for all projects in `~/.claude.json` |

## scripts/ vs hooks/

- **`scripts/`** — manual utilities, run on demand
- **`hooks/`** — auto-triggered by Claude Code lifecycle events (Stop, PostToolUse, etc.)

The `trust-flag-repair.sh` hook in `hooks/` runs automatically after every agent response. These scripts are for manual diagnosis and one-off repairs (e.g., after new worktree/project entries, cloning/moving projects, or config recreation).
