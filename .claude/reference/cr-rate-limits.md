# CodeRabbit Rate Limits & Behavior (Pro Tier)

Full detail extracted from `.claude/rules/cr-github-review.md` (the rule file keeps a summary + pointer to here). Loaded on demand, not every turn.

**Cap:** ~**8** GitHub PR reviews/hour + **50** chats/hour (tier variance — plan on **8**). One commit per fix batch before push. Max **2** explicit `@coderabbitai full review`/PR/hour (rolling 3600s); surface user at **2nd** recorded trigger.

**State:** `cr_hourly.events` (push consumption), `.prs[N].cr_explicit_triggers` (manual). Script `.claude/scripts/cr-review-hourly.sh`: `--check`, `--consume`, `--record-explicit N` (stderr SURFACE if ≥2); prune rolling hour; default budget **8** (`CR_HOURLY_BUDGET` = tests only).

**Cooldown / exhausted:** `cr-local-review.md` first; wait for window expiry (~≤60m) or escalation gate → BugBot → Greptile → self-review (`bugbot.md`, `greptile.md`). Parallel PRs: stagger (~3–4 CR-triggering pushes/hour).
