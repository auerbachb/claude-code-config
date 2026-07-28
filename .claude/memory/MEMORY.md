# Memory index (repo-tracked subset)

Cursor auto-memory normally lives under `~/.claude/projects/*/memory/`. This repo tracks durable notes that belong in git.

- [feedback_bugbot_auto_trigger_unreliable.md](feedback_bugbot_auto_trigger_unreliable.md) — Always post `@cursor review` on every PR push (CI + `/fixpr`); BugBot auto-trigger is unreliable; per-seat cost.
- [skill_usage_telemetry.md](skill_usage_telemetry.md) — `skill-usage.log` / `skill-usage.csv` live under `~/.claude/`; use `skill-usage-report.sh` for rollups; never log in skills worktree.
- [token_efficiency_verbosity.md](token_efficiency_verbosity.md) — token burn is structural (fixed context, repetition, fan-out), not stylistic; routine status = one line; playbook in `reference/token-efficiency-audit-2026-07.md`.
