# Skill Sync Hooks — How They Work

## Session-Start Sync Hook

The `session-start-sync.sh` PostToolUse hook runs once per session (on the first tool call) and syncs the skills worktree to `origin/main`. This ensures skills, rules, and CLAUDE.md are fresh across **all repos** — not just `claude-code-config`. The hook also pulls the root repo's `main` branch if it's currently checked out.

The `post-merge-pull.sh` hook syncs the skills worktree after merges and also refreshes the CLAUDE.md and rules symlinks.

## Hook Auto-Registration

The session-start sync also registers hooks from `global-settings.json` into `~/.claude/settings.json`. This ensures new hooks added to the template are picked up automatically — no need to re-run the setup script.

**How it works:**
- Reads `global-settings.json` from the skills worktree (always at `origin/main`)
- Resolves placeholder paths to the skills worktree hooks directory
- Compares against `~/.claude/settings.json` by script basename per event/matcher
- Adds only missing hooks; existing hooks (including user-customized timeouts) are preserved
- User hooks not in the template are never touched

**To add a new hook to the repo:**
1. Create the hook script in `.claude/hooks/`
2. Add the hook entry to `global-settings.json` (use the `/path/to/claude-code-config` placeholder)
3. Merge to `main` — the next session start auto-registers it in every user's `settings.json`
