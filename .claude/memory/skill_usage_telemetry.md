# Skill usage telemetry location

Skill invocations are logged under **`~/.claude/`** only:

- **`~/.claude/skill-usage.log`** — append-only, one tab-separated line per invocation: `ISO8601 UTC`, `skill_name`, `session_id`. Same storage pattern as `script-usage.log` (#310).

- **`~/.claude/skill-usage.csv`** — aggregated `use_count` / `last_used` for legacy workflows.

Do **not** store these logs inside the skills worktree: `session-start-sync.sh` can `git reset --hard` and wipe worktree-local state.

Rollups: run `bash .claude/scripts/skill-usage-report.sh` from the repo (see issue #416).

## Two capture paths (#584)

An invocation reaches the log through one of two hooks, both writing via the shared recorder `.claude/hooks/lib/skill-usage-recorder.sh`:

| Hook | Event | Catches |
|------|-------|---------|
| `skill-usage-tracker.sh` | PostToolUse, matcher `Skill` | model- and agent-initiated calls, chip threads |
| `skill-command-tracker.sh` | UserPromptSubmit | slash commands the user types |

Both are needed because a user-typed command reaches the model **pre-expanded** into the prompt (`<command-message>` + `<command-name>` blocks) and produces **no `Skill` tool call** — the model is instructed to follow an already-present command block rather than call the tool. That is by design, not a version gap, so the PostToolUse hook alone can never see typed invocations.

**Exactly-once dedupe:** the detector records, then drops a marker at `~/.claude/.skill-usage-pending/<session>__<skill>` holding the epoch it fired. A `Skill` call for the same session + skill consumes a fresh (≤30s) marker and skips its own line. Consume-once plus the freshness bound cap the failure modes at one line, and keep this correct if a future build starts emitting `Skill` calls for pre-expanded commands. The window is kept short (not the same-turn TTL a future build would actually need, plus margin) so a genuinely separate later Skill call for the same skill + session is never misattributed as the earlier typed invocation.

**Trust boundary for audits:** zeros recorded for user-typed skills **before 2026-07-16** are not evidence of disuse — the typed path logged nothing until #584 landed. `/issue-maker` was the proving case: demonstrably used, zero log lines. Weight pre-fix zeros accordingly (#573).

## Spend / thread-type telemetry (#710)

A second append-only log captures execution-type (thread vs inline) and model-tier attribution:

- **`~/.claude/spend-telemetry.log`** — TSV: `ISO8601Z event_type exec_type model_tier agent_type session_id agent_id tokens`

Two capture hooks, both writing via shared recorder `.claude/hooks/lib/spend-telemetry-recorder.sh`:

| Hook | Event | exec_type | Catches |
|------|-------|-----------|---------|
| `spend-session-tracker.sh` | SessionStart | `thread` | New standalone sessions (`startup` source only; compact/resume/clear skipped) |
| `spend-subagent-tracker.sh` | SubagentStop | `inline` | Each inline Agent-tool subagent completion |

**Token spend is best-effort only.** The `tokens` field is populated by parsing `agent_transcript_path` in the SubagentStop payload; it is empty on any failure. Empty ≠ zero spend.

**Model tier for inline runs** is derived from agent definition frontmatter, not measured at runtime.

**Observational-only.** This data MUST NOT gate any agent decision or quota check (`safety.md` §"Anthropic Quota & Spend Authority").

Report: `bash .claude/scripts/spend-telemetry-report.sh [--days N]`. Schema + caveats: `.claude/reference/spend-telemetry-pipeline.md`.
