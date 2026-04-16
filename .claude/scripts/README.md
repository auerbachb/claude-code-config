# .claude/scripts/

Manually-invoked utility scripts. Run these from the command line when needed.

| Script | Purpose |
|--------|---------|
| `pr-state.sh [--pr N] [--since <iso-8601>]` | Gather full PR state into a single JSON file (threads, CI check-runs, commit statuses, 3 comment endpoints, merge state, optional since-baseline classifier). Shared by `/fixpr`, `/merge`, `/wrap`, `/continue`, `/status`, `phase-b-reviewer`, `phase-c-merger`. **Output:** writes to `/tmp/pr-state-<PR>-<epoch>.json` and prints the path on stdout — the OS reclaims `/tmp/` on reboot, so callers need not delete these files. Exit codes: `0` OK, `2` usage, `3` no branch + no `--pr`, `4` PR closed/not found, `5` gh/network error. |
| `cr-plan.sh <issue_number> [--poll <min>] [--max-age-minutes N]` | Detect a CodeRabbit implementation-plan comment on a GitHub issue. Prints plan body on stdout. Exits `0` plan found, `1` no plan, `2` usage error, `3` issue not found/closed, `4` gh error. Used by `/start-issue`, `/subagent`, `pm-worker`. |
| `repair-trust-single.sh <absolute-project-path>` | Fix trust flags for one project in `~/.claude.json` |
| `repair-trust-all.sh` | Fix trust flags for all projects in `~/.claude.json` |
| `repair-worktrees.sh [--apply]` | Detect stale git worktrees (branch merged to main or deleted on origin) and optionally remove them. Dry-run by default; skips worktrees with uncommitted changes and never touches the main worktree. |
| `cycle-count.sh <pr_number> [--exclude-bots]` | Reconstruct per-PR review-then-fix cycle count. Prints an integer on stdout. Used by `/merge`, `/wrap`, `/pm-rate-team`, `/pm-sprint-review`. See `--help` and `.claude/reference/pm-data-patterns.md` "Review cycles per PR". |
| `audit-skill-usage.sh` | Monthly skill-usage audit against `.claude/data/skill-usage.json`. |
| `resolve-review-threads.sh <pr_number> [--authors a,b,c] [--dry-run]` | Fetch unresolved PR review threads via GraphQL, filter to bot authors (default: `coderabbitai,cursor,greptile-apps`), and resolve each via `resolveReviewThread` (fallback: `minimizeComment`). Used by `/fixpr`, `/continue`, and `phase-a-fixer`. Exit codes: 0 OK, 1 ≥1 thread failed both mutations, 2 usage, 3 PR not found, 4 gh error. |
| `merge-gate.sh <pr_number> [--reviewer cr\|bugbot\|greptile]` | Verify the merge gate for a PR per `.claude/rules/cr-merge-gate.md` (CR 2-clean / BugBot 1-clean / Greptile severity + CI + BEHIND). Prints JSON on stdout. Exits `0` gate met, `1` gate not met, `2` usage, `3` PR not found, `4` gh error. Called from `/merge`, `/wrap`, `/continue`, `/status`, and the `phase-c-merger` agent. |

## scripts/ vs hooks/

- **`scripts/`** — manual utilities, run on demand
- **`hooks/`** — auto-triggered by Claude Code lifecycle events (Stop, PostToolUse, etc.)

The `trust-flag-repair.sh` hook in `hooks/` runs automatically after every agent response. These scripts are for manual diagnosis and one-off repairs (e.g., after new worktree/project entries, cloning/moving projects, or config recreation).
