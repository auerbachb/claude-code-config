# Skill usage telemetry location

Skill invocations are logged under **`~/.claude/`** only:

- **`~/.claude/skill-usage.log`** — append-only, one tab-separated line per `Skill` tool call: `ISO8601 UTC`, `skill_name`, `session_id`. Written by `.claude/hooks/skill-usage-tracker.sh` (PostToolUse, matcher `Skill`). Same storage pattern as `script-usage.log` (#310).

- **`~/.claude/skill-usage.csv`** — aggregated `use_count` / `last_used` for legacy workflows; still updated by the same hook.

Do **not** store these logs inside the skills worktree: `session-start-sync.sh` can `git reset --hard` and wipe worktree-local state.

Rollups: run `bash .claude/scripts/skill-usage-report.sh` from the repo (see issue #416).
