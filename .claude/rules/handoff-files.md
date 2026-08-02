# Handoff Files & Session State

> **Always:** Write handoff files on phase completion. Read handoff files before reconstructing state from GitHub API. Update session-state.json on phase transitions. Preserve unknown fields in handoff files.
> **Ask first:** Never — handoff file operations are autonomous.
> **Never:** Skip writing the handoff file. Delete one before successful merge. Strip unrecognized fields. Write `session-state.json` outside `session-state.sh` or handoff files outside `handoff-state.sh` — inline `jq … > tmp && mv tmp` bypasses the respective write lock.

## State Files

- `~/.claude/session-state.json`: session-wide orchestration (per-repo `prs`, active agents, Greptile daily budget, **CodeRabbit hourly consumption** in `cr_hourly.events`, per-PR `cr_explicit_triggers`, polling failures). Full schema: `.claude/reference/session-state-schema.json`.
- `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json`: per-PR phase details for the next phase.
- **Polling:** Parent runs `polling-state-gate.sh N --ensure-session` once, then `polling-state-gate.sh N` each cycle. Subagent handoffs overwrite the same file at phase end.

**Writes.** Update `session-state.json` on phase transitions and key events (agent launched/completed, review received, dropped poll recovered). **All writes go through `.claude/scripts/session-state.sh --set <jq-path>=<value>`** (read with `--get`); it preserves siblings, writes atomically, and holds the lock. Handoff writes go through `handoff-state.sh`. Both exit **6** on lock timeout — retry.

**Scope.** State lives at `.repos["<owner>/<name>"].prs["<N>"]` (always lowercase), auto-scoped from `--repo`, `$CLAUDE_SESSION_REPO`, or cwd origin. Account-level fields stay global. Repair with `session-state-audit.sh --apply --reattribute` if entries land in `_unknown`.

**Read scope.** Use `session-state.sh --session-view` — **never `--get .`** (cross-repo leak). Cross-repo reporting is opt-in (`--all-repos`). Never write against a PR outside the invoking repo.

**Field types.** Wrong `--set` type exits **4** (unmodified). **Never pass a raw jq filter as a `--set` value** — evaluate first.

Mechanism + migration: `.claude/reference/state-file-contracts.md`. Canonical contracts: `session-state.sh --help`, `handoff-state.sh --help`, `state-lock.sh` header.

## Handoff File Storage

- **Naming:** `{owner}/{repo}/pr-{N}-handoff.json`. Create via `handoff-state.sh --owner-repo <owner>/<repo> --create`; resolve path with `handoff-state.sh --path <N>`.
- **One file per PR per repo at any time** — two repos at the same PR number occupy different paths.
- **Lifecycle:** Created by Phase A → read/updated by Phase B → read by Phase C → deleted by **parent** after `OUTCOME: merged` confirmed by GitHub (see `phase-protocols.md`).

### Phase Operations

| Phase | Operation |
|-------|-----------|
| A | Create with fixed/dismissed findings, replied/resolved threads, files changed, HEAD SHA |
| B | Read-modify-write; append arrays, update scalars, preserve unknown fields |
| C | Read only; deletion timing per `phase-protocols.md` |

Required and optional fields: `.claude/reference/handoff-file-schema.json` (single source of truth). Note `stale_bot_reviews_dismissed` — review IDs dismissed by `dismiss-stale-bot-changes.sh` after a push.

**Forward compatibility:** preserve unknown fields; dedupe string arrays by value, `findings_dismissed` by `.id`.

## Token Exhaustion Handoff

Near exhaustion (protocol: `subagent-orchestration.md`): write the token-exhaustion handoff fields to `session-state.json` (schema: `.claude/reference/session-state-schema.json` `_token_exhaustion_example`), then exit cleanly.

