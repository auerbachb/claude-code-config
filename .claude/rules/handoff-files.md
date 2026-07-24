# Handoff Files & Session State

> **Always:** Write handoff files on phase completion. Read handoff files before reconstructing state from GitHub API. Update session-state.json on phase transitions. Preserve unknown fields in handoff files.
> **Ask first:** Never — handoff file operations are autonomous.
> **Never:** Skip writing the handoff file. Delete one before successful merge. Strip unrecognized fields. Write `session-state.json` outside `session-state.sh` or handoff files outside `handoff-state.sh` — inline `jq … > tmp && mv tmp` bypasses the respective write lock.

## State Files

- `~/.claude/session-state.json`: session-wide orchestration (per-repo `prs`, active agents, Greptile daily budget, **CodeRabbit hourly consumption** in `cr_hourly.events`, per-PR `cr_explicit_triggers`, polling failures). Full schema: `.claude/reference/session-state-schema.json`.
- `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json`: per-PR phase details consumed by the next phase. Legacy flat files are preserved; `handoff-migrate.sh --apply` moves them to the scoped layout.
- **Polling:** Parent runs `polling-state-gate.sh N --ensure-session` once, then `polling-state-gate.sh N` each cycle. Subagent handoffs overwrite the same file at phase end.

**Writes.** Update `session-state.json` on phase transitions and key events (agent launched/completed, review received, dropped poll recovered). **All writes go through `.claude/scripts/session-state.sh --set <jq-path>=<value>`** (read with `--get`); it preserves siblings, writes atomically, and holds the lock. Handoff writes go through `handoff-state.sh`. Both exit **6** on lock timeout — retry.

**Scope.** State lives at `.repos["<owner>/<name>"].prs["<N>"]`, auto-scoped from `--repo`, `$CLAUDE_SESSION_REPO`, or cwd origin. The key is **always lowercase**, as are `~/.claude/handoffs/{owner}/{repo}/` paths. Account-level fields stay global. Unattributable legacy entries land in `_unknown` and still collide in `infer-pr.sh`/`pr-state.sh` candidates — repair with `session-state-audit.sh --apply --reattribute` (`--prune` drops merged ones).

**Read scope.** Orchestration skills use `session-state.sh --session-view` (repo-scoped projection) — **never `--get .`** (aggregates every repo; cross-repo leak). Cross-repo reporting is opt-in via `--session-view --all-repos`. Never write (merge/rebase/close) against a PR outside the invoking repo.

**Field types.** Wrong-type `--set` exits **4** (file unmodified); corrupted `--get` warns and returns a safe default. **Never pass a raw jq filter as a `--set` value** — evaluate first.

Mechanism, migration, and rationale: `.claude/reference/state-file-contracts.md` (issues #625, #638, #639, #651, #655, #682, #687, #704). Canonical contracts: `session-state.sh --help`, `handoff-state.sh --help`, `state-lock.sh` header.

## Handoff File Storage

- **Naming:** `{owner}/{repo}/pr-{N}-handoff.json` (e.g. `auerbachb/claude-code-config/pr-618-handoff.json`). Create via `handoff-state.sh --owner-repo <owner>/<repo> --create` (it `mkdir -p`s the subdirectory); resolve the path with `handoff-state.sh [--owner-repo <owner>/<repo>] --path <N>`.
- **One file per PR per repo at any time.** Two repos at the same PR number occupy different paths (issue #655).
- **Lifecycle:** Created by Phase A → read/updated by Phase B → read by Phase C → deleted by **parent** after `OUTCOME: merged` confirmed by GitHub (see `phase-protocols.md`).

### Phase Operations

| Phase | Operation |
|-------|-----------|
| A | Create with fixed/dismissed findings, replied/resolved threads, files changed, HEAD SHA |
| B | Read-modify-write; append arrays, update scalars, preserve unknown fields |
| C | Read only; deletion timing per `phase-protocols.md` |

Required and optional fields: `.claude/reference/handoff-file-schema.json` (single source of truth). Note `stale_bot_reviews_dismissed` — review IDs dismissed by `dismiss-stale-bot-changes.sh` after a `/fixpr` push (issue #426).

**Forward compatibility:** preserve unknown fields; dedupe string arrays by value, `findings_dismissed` by `.id`.

## Token Exhaustion Handoff

Near exhaustion (protocol: `subagent-orchestration.md`), write `{phase, needs: "continue_polling", handoff_reason: "token_exhaustion", last_action, remaining_work, head_sha}` to `session-state.json` (full example: `.claude/reference/session-state-schema.json`, `_token_exhaustion_example`), report done/remaining, and exit cleanly — the parent auto-launches a replacement for the same phase.

