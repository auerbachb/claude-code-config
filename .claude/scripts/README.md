# .claude/scripts/

Manually-invoked utility scripts. Run these from the command line when needed.

| Script | Purpose |
|--------|---------|
| `cr-plan.sh <issue_number> [--poll <min>] [--max-age-minutes N]` | Detect a CodeRabbit implementation-plan comment on a GitHub issue. Prints plan body on stdout. Exits `0` plan found, `1` no plan, `2` usage error, `3` issue not found/closed, `4` gh error. Used by `/start-issue`, `/subagent`, `pm-worker`. |
| `repair-trust-single.sh <absolute-project-path>` | Fix trust flags for one project in `~/.claude.json` |
| `repair-trust-all.sh` | Fix trust flags for all projects in `~/.claude.json` |
| `repair-worktrees.sh [--apply]` | Detect stale git worktrees (branch merged to main or deleted on origin) and optionally remove them. Dry-run by default; skips worktrees with uncommitted changes and never touches the main worktree. |
| `cycle-count.sh <pr_number> [--exclude-bots]` | Reconstruct per-PR review-then-fix cycle count. Prints an integer on stdout. Used by `/merge`, `/wrap`, `/pm-rate-team`, `/pm-sprint-review`. See `--help` and `.claude/reference/pm-data-patterns.md` "Review cycles per PR". |
| `audit-skill-usage.sh` | Monthly skill-usage audit against `.claude/data/skill-usage.json`. |
| `resolve-review-threads.sh <pr_number> [--authors a,b,c] [--dry-run]` | Fetch unresolved PR review threads via GraphQL, filter to bot authors (default: `coderabbitai,cursor,greptile-apps`), and resolve each via `resolveReviewThread` (fallback: `minimizeComment`). Used by `/fixpr`, `/continue`, and `phase-a-fixer`. Exit codes: 0 OK, 1 ≥1 thread failed both mutations, 2 usage, 3 PR not found, 4 gh error. |

## scripts/ vs hooks/

- **`scripts/`** — manual utilities, run on demand
- **`hooks/`** — auto-triggered by Claude Code lifecycle events (Stop, PostToolUse, etc.)

The `trust-flag-repair.sh` hook in `hooks/` runs automatically after every agent response. These scripts are for manual diagnosis and one-off repairs (e.g., after new worktree/project entries, cloning/moving projects, or config recreation).
