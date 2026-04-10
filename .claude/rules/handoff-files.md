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

```json
{
  "last_updated": "2026-03-16T16:00:00Z",
  "monitoring_active": true,
  "root_repo": "/Users/user/repos/my-project",
  "work_log_path": "docs/work-logs",
  "prs": {
    "618": {"phase": "B", "head_sha": "7b2cfbf", "reviewer": "cr", "needs": "cr_confirmation_pass"},
    "620": {"phase": "B", "head_sha": "d0e4fef", "reviewer": "g", "needs": "fix_and_push"}
  },
  "cr_quota": {"reviews_used": 5, "window_start": "2026-03-16T15:00:00Z"},
  "greptile_daily": {"reviews_used": 12, "date": "2026-03-16", "budget": 40},
  "active_agents": [
    {"id": "a3f8d26fa75eddcb3", "task": "PR #623 Phase C", "launched": "2026-03-16T15:55:00Z"}
  ]
}
```

Write on phase transitions (A→B, B→C) and key state-change events (agent launched, completed, review received).

## Handoff File Storage

- **Location:** `~/.claude/handoffs/` (create if missing: `mkdir -p ~/.claude/handoffs/`)
- **Naming:** `pr-{N}-handoff.json` (e.g., `pr-618-handoff.json`)
- **One file per PR at any time.**
- **Lifecycle:** Created by Phase A → read/updated by Phase B → read then deleted by Phase C after merge.

### Phase-Specific Operations

| Phase | Operation | Details |
|-------|-----------|---------|
| A | **Create** | Write initial handoff with all findings fixed, threads replied/resolved, files changed, HEAD SHA |
| B | **Read-modify-write** | Read existing file, merge changes (append new array entries, update scalars), preserve unknown fields, write back. **Deduplicate:** `string[]` fields by exact value; `findings_dismissed` by `.id` |
| C | **Read then delete** | Read for context (reviewer, phase_completed). Delete only after successful merge. If merge fails, do NOT delete |

## Handoff File Schema

```json
{
  "schema_version": "1.0",
  "pr_number": 618,
  "head_sha": "abc1234",
  "reviewer": "cr",
  "phase_completed": "A",
  "created_at": "2026-03-24T17:00:00Z",
  "findings_fixed": ["comment-id-1", "comment-id-2"],
  "findings_dismissed": [
    {"id": "comment-id-3", "reason": "false positive — code already handles this case"}
  ],
  "threads_replied": ["thread-id-1", "thread-id-2"],
  "threads_resolved": ["thread-id-1", "thread-id-2"],
  "files_changed": ["src/foo.ts", "src/bar.ts"],
  "push_timestamp": "2026-03-24T17:00:00Z",
  "notes": "CR had 3 findings, all fixed. 1 dismissed as false positive."
}
```

### Field Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `schema_version` | string | yes | Always `"1.0"` |
| `pr_number` | number | yes | The PR number |
| `head_sha` | string | yes | HEAD SHA after the phase's last push |
| `reviewer` | string | yes | `"cr"` or `"greptile"` |
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

When approaching token exhaustion (see `subagent-orchestration.md` "Token/Turn Exhaustion Protocol"), write a handoff to `session-state.json` with:

```json
{
  "phase": "B",
  "needs": "continue_polling",
  "handoff_reason": "token_exhaustion",
  "last_action": "pushed fixes at SHA abc1234, replied to 3/5 threads",
  "remaining_work": ["reply to threads 4-5", "poll for next review"],
  "head_sha": "abc1234"
}
```

Report concisely to the parent/user what was done and what remains. Exit cleanly — do not squeeze in one more tool call.

**Parent response to exhaustion:** Read `session-state.json`, launch a replacement subagent for the same phase. This is an **"Always do"** action — do not ask the user.
