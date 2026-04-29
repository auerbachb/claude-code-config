# Handoff Files & Session State

> **Always:** Write handoff files on phase completion. Read handoff files before reconstructing state from GitHub API. Update session-state.json on phase transitions. Preserve unknown fields in handoff files.
> **Ask first:** Never — handoff file operations are autonomous.
> **Never:** Skip writing the handoff file. Delete a handoff file before successful merge. Strip unrecognized fields from handoff files.

## State Files

- `~/.claude/session-state.json`: session-wide orchestration (`prs`, active agents, reviewer quotas, polling failures). Full schema: `.claude/reference/session-state-schema.json`.
- `~/.claude/handoffs/pr-{N}-handoff.json`: per-PR phase details consumed by the next phase.

Update `session-state.json` on phase transitions and key events (agent launched/completed, review received, dropped poll recovered). Prefer `.claude/scripts/session-state.sh --set <jq-path>=<value>` / `--get <jq-path>`; it preserves siblings and writes atomically.

## Handoff File Storage

- **Location:** `~/.claude/handoffs/` (create if missing: `mkdir -p ~/.claude/handoffs/`)
- **Naming:** `pr-{N}-handoff.json` (e.g., `pr-618-handoff.json`)
- **One file per PR at any time.**
- **Lifecycle:** Created by Phase A → read/updated by Phase B → read by Phase C for context → deleted by **parent** after successful user-gated merge (see `phase-protocols.md`).

### Phase Operations

| Phase | Operation |
|-------|-----------|
| A | Create with fixed/dismissed findings, replied/resolved threads, files changed, HEAD SHA |
| B | Read-modify-write; append arrays, update scalars, preserve unknown fields |
| C | Read only; parent deletes only after successful user-gated merge |

Schema reference: `.claude/reference/handoff-file-schema.json`. Required fields: `schema_version`, `pr_number`, `head_sha`, `reviewer`, `phase_completed`, `created_at`, `findings_fixed`, `threads_replied`, `threads_resolved`, `files_changed`, `push_timestamp`. Optional: `findings_dismissed`, `notes`.

**Forward compatibility:** preserve unknown fields; dedupe string arrays by exact value and `findings_dismissed` by `.id`.

## Token Exhaustion Handoff

When approaching token exhaustion (see `subagent-orchestration.md` "Token/Turn Exhaustion Protocol"), write a handoff to `session-state.json` with `{phase, needs: "continue_polling", handoff_reason: "token_exhaustion", last_action, remaining_work, head_sha}`. Full example: `.claude/reference/session-state-schema.json` (see `_token_exhaustion_example`).

Report concisely to the parent/user what was done and what remains. Exit cleanly — do not squeeze in one more tool call.

**Parent response to exhaustion:** Read `session-state.json`, launch a replacement subagent for the same phase. This is an **"Always do"** action — do not ask the user.

## Session-State Schema

Full schema/examples: `.claude/reference/session-state-schema.json`. Preserve unknown fields. Per-PR polling fields under `prs.{N}`:

| Field | Meaning |
|-------|---------|
| `digest` | Polling digest: `(head_sha, cr_state, bugbot_state, greptile_state, ci_blocking_conclusions_sorted, blocker_kind)`; excludes free-text `blocker`. |
| `digest_streak` | Consecutive identical ticks; drives backoff (see `scheduling-reliability.md`). |
| `blocker` | Human-readable blocker, or `null`. |
| `blocker_kind` | `"user_input"`, `"ci_external"`, `"review_pending"`, or `null`. |
| `last_cron_action` | Last scheduler action `{type, at, interval}`; suppresses duplicate hook warnings. |
