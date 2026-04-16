# .claude/scripts/

Manually-invoked utility scripts. Run these from the command line when needed.

| Script | Purpose |
|--------|---------|
| `repair-trust-single.sh <absolute-project-path>` | Fix trust flags for one project in `~/.claude.json` |
| `repair-trust-all.sh` | Fix trust flags for all projects in `~/.claude.json` |
| `repair-worktrees.sh [--apply]` | Detect stale git worktrees (branch merged to main or deleted on origin) and optionally remove them. Dry-run by default; skips worktrees with uncommitted changes and never touches the main worktree. |
| `cycle-count.sh <pr_number> [--exclude-bots]` | Reconstruct per-PR review-then-fix cycle count. Prints an integer on stdout. Used by `/merge`, `/wrap`, `/pm-rate-team`, `/pm-sprint-review`. See `--help` and `.claude/reference/pm-data-patterns.md` "Review cycles per PR". |
| `audit-skill-usage.sh` | Monthly skill-usage audit against `.claude/data/skill-usage.json`. |

## scripts/ vs hooks/

- **`scripts/`** — manual utilities, run on demand
- **`hooks/`** — auto-triggered by Claude Code lifecycle events (Stop, PostToolUse, etc.)

The `trust-flag-repair.sh` hook in `hooks/` runs automatically after every agent response. These scripts are for manual diagnosis and one-off repairs (e.g., after new worktree/project entries, cloning/moving projects, or config recreation).
