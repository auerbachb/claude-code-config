# Handoff Files & Session State

> **Always:** Write handoff files on phase completion. Read handoff files before reconstructing state from GitHub API. Update session-state.json on phase transitions. Preserve unknown fields in handoff files.
> **Ask first:** Never — handoff file operations are autonomous.
> **Never:** Skip writing the handoff file. Delete a handoff file before successful merge. Strip unrecognized fields from handoff files.

## State Files

- `~/.claude/session-state.json`: session-wide orchestration (`prs`, active agents, Greptile daily budget, **CodeRabbit hourly consumption** in `cr_hourly.events`, per-PR `cr_explicit_triggers`, polling failures). Full schema: `.claude/reference/session-state-schema.json`.
- `~/.claude/handoffs/pr-{N}-handoff.json`: per-PR phase details consumed by the next phase.
- **Polling:** Parent runs `polling-state-gate.sh N --ensure-session` once, then `polling-state-gate.sh N` each cycle (see script). Subagent handoffs overwrite the same file when a phase finishes.

Update `session-state.json` on phase transitions and key events (agent launched/completed, review received, dropped poll recovered). Prefer `.claude/scripts/session-state.sh --set <jq-path>=<value>` / `--get <jq-path>`; it preserves siblings and writes atomically.

**Field-type contract (issue #625):** `session-state.sh` enforces expected JSON types on known top-level fields (`active_agents`, `prs`, …): a `--set` storing the wrong type is rejected (exit 4, file unmodified); a `--get` on a corrupted field warns and returns a safe default so the next validated write self-heals. **Never pass a raw jq filter as a `--set` value** — evaluate it locally first and pass the resulting JSON. Full contract: `session-state.sh`'s header comment (single source of truth).

## Handoff File Storage

- **Location:** `~/.claude/handoffs/` (create if missing: `mkdir -p ~/.claude/handoffs/`)
- **Naming:** `pr-{N}-handoff.json` (e.g., `pr-618-handoff.json`)
- **One file per PR at any time.**
- **Lifecycle:** Created by Phase A → read/updated by Phase B → read by Phase C → deleted by **parent** after `OUTCOME: merged` confirmed by GitHub (see `phase-protocols.md`).

### Phase Operations

| Phase | Operation |
|-------|-----------|
| A | Create with fixed/dismissed findings, replied/resolved threads, files changed, HEAD SHA |
| B | Read-modify-write; append arrays, update scalars, preserve unknown fields |
| C | Read only; deletion timing per `phase-protocols.md` |

Schema reference: `.claude/reference/handoff-file-schema.json`. Required fields: `schema_version`, `pr_number`, `head_sha`, `reviewer`, `phase_completed`, `created_at`, `findings_fixed`, `threads_replied`, `threads_resolved`, `files_changed`, `push_timestamp`. Optional: `findings_dismissed`, `stale_bot_reviews_dismissed` (GitHub review IDs dismissed by `dismiss-stale-bot-changes.sh` after a `/fixpr` push — issue #426), `notes`.

**Forward compatibility:** preserve unknown fields; dedupe string arrays by exact value and `findings_dismissed` by `.id`.

## Token Exhaustion Handoff

Near exhaustion (protocol: `subagent-orchestration.md`), write `{phase, needs: "continue_polling", handoff_reason: "token_exhaustion", last_action, remaining_work, head_sha}` to `session-state.json` (full example: `.claude/reference/session-state-schema.json`, `_token_exhaustion_example`), report done/remaining, and exit cleanly — the parent auto-launches a replacement for the same phase.

