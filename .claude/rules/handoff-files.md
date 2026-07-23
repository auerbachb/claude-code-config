# Handoff Files & Session State

> **Always:** Write handoff files on phase completion. Read handoff files before reconstructing state from GitHub API. Update session-state.json on phase transitions. Preserve unknown fields in handoff files.
> **Ask first:** Never — handoff file operations are autonomous.
> **Never:** Skip writing the handoff file. Delete one before successful merge. Strip unrecognized fields. Write `session-state.json` outside `session-state.sh` or handoff files outside `handoff-state.sh` — inline `jq … > tmp && mv tmp` bypasses the respective write lock.

## State Files

- `~/.claude/session-state.json`: session-wide orchestration (per-repo `prs`, active agents, Greptile daily budget, **CodeRabbit hourly consumption** in `cr_hourly.events`, per-PR `cr_explicit_triggers`, polling failures). Full schema: `.claude/reference/session-state-schema.json`.
- `~/.claude/handoffs/{owner}/{repo}/pr-{N}-handoff.json`: per-PR phase details consumed by the next phase. Pass `--owner-repo <owner>/<repo>` to `handoff-state.sh`; use `handoff-state.sh --owner-repo ... --path <N>` to resolve the canonical path. Legacy flat path `~/.claude/handoffs/pr-{N}-handoff.json` is preserved during migration; run `handoff-migrate.sh --apply` to move flat files to the scoped layout.
- **Polling:** Parent runs `polling-state-gate.sh N --ensure-session` once, then `polling-state-gate.sh N` each cycle. Subagent handoffs overwrite the same file at phase end.

**Repo scoping (issue #638):** State lives at `.repos["<owner>/<name>"].prs["<N>"]`; `session-state.sh` auto-scopes calls via `--repo`, `$CLAUDE_SESSION_REPO`, or cwd origin. Unattributable legacy entries land in `_unknown`. Account-level fields stay global. See `session-state.sh --help`.

**Scope-key case normalization (issue #704):** The `.repos["<owner>/<name>"]` scope key is **always lowercase**. All three derivation points — `session-state.sh`'s `repo_key_from_remote_url()`/`resolve_repo_key()`, `polling-state-gate.sh`'s `repo_identity()`, and `handoff-state.sh`'s path resolver — share a single normalizer (`lib/repo-normalizer.sh`) so a mixed-case remote URL (`AuerbachB/Skingod`) and its lowercase form (`auerbachb/skingod`) always map to the same scope. Handoff paths follow the same contract: `~/.claude/handoffs/{owner}/{repo}/` directories are always lowercase. Existing live keys are already lowercase, so this is backward-compatible.

**Invoking-repo scope (issue #687):** Orchestration skills use `session-state.sh --session-view` (repo-scoped projection) — **never `--get .`** (aggregates every repo; cross-repo leak). Cross-repo reporting is opt-in via `--session-view --all-repos`. Never write (merge/rebase/close) against a PR outside the invoking repo.

Update `session-state.json` on phase transitions and key events (agent launched/completed, review received, dropped poll recovered). **All writes go through `.claude/scripts/session-state.sh --set <jq-path>=<value>`** (read with `--get`); it preserves siblings, writes atomically, and holds the lock below.

**Write lock (issue #639):** `session-state.sh` serializes reads/writes via `state-lock.sh` (`mkdir` lockdir; macOS has no `flock(1)`). Exit **6** = lock timeout (unchanged, retry); dead-holder locks self-heal. `greptile-budget.sh` and `cr-review-hourly.sh` share the same library. Failure modes: `state-lock.sh` header.

**Write lock (issue #682):** Handoff writes use `handoff-state.sh` (same `state-lock.sh` as #639). Exit **6** = lock timeout (unchanged, retry).

**Scoping is not retroactive (issue #651):** Legacy entries without `owner_repo`/`root_repo` land in `_unknown` and still collide in `infer-pr.sh`/`pr-state.sh` candidates. Repair: `session-state-audit.sh --apply --reattribute` (moves entries by SHA; `--prune` drops merged ones). Backs up first, holds the lock, re-checks integrity.

**Field-type contract (issue #625):** `session-state.sh` enforces JSON types on known fields: wrong-type `--set` exits **4** (file unmodified); corrupted `--get` warns + returns a safe default. **Never pass a raw jq filter as a `--set` value** — evaluate first. Full contract: `session-state.sh` header (single source of truth).

## Handoff File Storage

- **Location:** `~/.claude/handoffs/{owner}/{repo}/` (create via `handoff-state.sh --owner-repo <owner>/<repo> --create`; the helper calls `mkdir -p` on the subdirectory automatically). Legacy flat files live at `~/.claude/handoffs/` — run `handoff-migrate.sh --apply` to migrate them.
- **Naming:** `{owner}/{repo}/pr-{N}-handoff.json` (e.g., `auerbachb/claude-code-config/pr-618-handoff.json`). Resolve the canonical path with `handoff-state.sh [--owner-repo <owner>/<repo>] --path <N>`.
- **One file per PR per repo at any time.** Two repos at the same PR number now occupy different paths (issue #655 fixed).
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

