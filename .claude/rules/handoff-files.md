# Handoff Files & Session State

> **Always:** Write handoff files on phase completion. Read handoff files before reconstructing state from GitHub API. Update session-state.json on phase transitions. Preserve unknown fields in handoff files.
> **Ask first:** Never — handoff file operations are autonomous.
> **Never:** Skip writing the handoff file. Delete a handoff file before successful merge. Strip unrecognized fields from handoff files.

## Two-File State System

| File | Scope | Purpose |
|------|-------|---------|
| `~/.claude/session-state.json` | Session-wide | High-level orchestration: which PRs exist, what phase each is in, CR/Greptile quota, active agents |
| `~/.claude/handoffs/pr-{N}-handoff.json` | Per-PR | Detailed phase state: findings fixed, threads replied/resolved, files changed — consumed by the next phase |

`session-state.json` must be updated on phase transitions. Handoff files complement it with detailed per-PR context that subagents need.

## Session-State Schema

Full example JSON (including the token-exhaustion handoff shape): `.claude/reference/session-state-schema.json`.

Top-level keys: `last_updated`, `monitoring_active`, `root_repo`, `work_log_path`, `prs` (map of PR number → `{phase, head_sha, reviewer, needs}`), `cr_quota` (`{reviews_used, window_start}`), `greptile_daily` (`{reviews_used, date, budget}`), `active_agents` (array of `{id, task, launched}`).

Write on phase transitions (A→B, B→C) and key state-change events (agent launched, completed, review received). Use `.claude/scripts/session-state.sh --set <jq-path>=<value> [--set ...]` for surgical writes — it preserves sibling fields, batches multiple `--set` flags into one atomic temp+mv, and refreshes `.last_updated` automatically. Use `--get <jq-path>` for reads. Avoid hand-rolling `jq … > tmp && mv tmp file` blocks for this file.

## Handoff File Storage

- **Location:** `~/.claude/handoffs/` (create if missing: `mkdir -p ~/.claude/handoffs/`)
- **Naming:** `pr-{N}-handoff.json` (e.g., `pr-618-handoff.json`)
- **One file per PR at any time.**
- **Lifecycle:** Created by Phase A → read/updated by Phase B → read by Phase C for context → deleted by **parent** after successful user-gated merge (see `phase-protocols.md`).

### Phase-Specific Operations

| Phase | Operation | Details |
|-------|-----------|---------|
| A | **Create** | Write initial handoff with all findings fixed, threads replied/resolved, files changed, HEAD SHA |
| B | **Read-modify-write** | Read existing file, merge changes (append new array entries, update scalars), preserve unknown fields, write back. **Deduplicate:** `string[]` fields by exact value; `findings_dismissed` by `.id` |
| C | **Read only** | Phase C subagents read for context (reviewer, phase_completed) and verify/report. **Parent** deletes the file after successful user-gated merge. If merge fails, do NOT delete |

## Handoff File Schema

Full example JSON: `.claude/reference/handoff-file-schema.json`.

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | string | yes | Always `"1.0"` |
| `pr_number` | number | yes | The PR number |
| `head_sha` | string | yes | HEAD SHA after the phase's last push |
| `reviewer` | string | yes | `"cr"`, `"bugbot"`, or `"greptile"` |
| `phase_completed` | string | yes | `"A"`, `"B"`, or `"C"` |
| `created_at` | string | yes | ISO 8601 timestamp |
| `findings_fixed` | string[] | yes | Comment/review IDs of fixed findings |
| `findings_dismissed` | object[] | no | Findings dismissed with `{id, reason}` |
| `threads_replied` | string[] | yes | Thread IDs where a reply was posted |
| `threads_resolved` | string[] | yes | Thread IDs resolved via GraphQL |
| `files_changed` | string[] | yes | File paths modified during the phase |
| `push_timestamp` | string | yes | ISO 8601 timestamp of last push |
| `notes` | string | no | Free-text summary for debugging |

**Forward compatibility:** Unknown fields must be preserved when reading and rewriting. Do not strip fields you don't recognize.

## Token Exhaustion Handoff

When approaching token exhaustion (see `subagent-orchestration.md` "Token/Turn Exhaustion Protocol"), write a handoff to `session-state.json` with `{phase, needs: "continue_polling", handoff_reason: "token_exhaustion", last_action, remaining_work, head_sha}`. Full example: `.claude/reference/session-state-schema.json` (see `_token_exhaustion_example`).

Report concisely to the parent/user what was done and what remains. Exit cleanly — do not squeeze in one more tool call.

**Parent response to exhaustion:** Read `session-state.json`, launch a replacement subagent for the same phase. This is an **"Always do"** action — do not ask the user.
