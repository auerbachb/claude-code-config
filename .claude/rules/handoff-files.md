# Handoff Files & Session State

> **Always:** Write handoff files on phase completion. Read handoff files before reconstructing state from GitHub API. Update session-state.json on phase transitions. Preserve unknown fields in handoff files.
> **Ask first:** Never — handoff file operations are autonomous.
> **Never:** Skip writing the handoff file. Delete one before successful merge. Strip unrecognized fields. Write `session-state.json` outside `session-state.sh` — an inline `jq … > tmp && mv tmp` bypasses the write lock.

## State Files

- `~/.claude/session-state.json`: session-wide orchestration (per-repo `prs`, active agents, Greptile daily budget, **CodeRabbit hourly consumption** in `cr_hourly.events`, per-PR `cr_explicit_triggers`, polling failures). Full schema: `.claude/reference/session-state-schema.json`.
- `~/.claude/handoffs/pr-{N}-handoff.json`: per-PR phase details consumed by the next phase.
- **Polling:** Parent runs `polling-state-gate.sh N --ensure-session` once, then `polling-state-gate.sh N` each cycle. Subagent handoffs overwrite the same file at phase end.

**Repo scoping (issue #638):** PR state lives at `.repos["<owner>/<name>"].prs["<N>"]`, so two repos at one PR number no longer collide; `root_repo` is per-repo too. Callers keep existing paths — `session-state.sh` rewrites a leading `.prs`/`.root_repo` into the active scope (`--repo`, `$CLAUDE_SESSION_REPO`, or cwd's `origin`) and migrates legacy state, keeping unattributable entries under `_unknown`. Account-level fields (`cr_hourly`, `greptile_daily`) stay global. See `session-state.sh --help`.

**Invoking-repo scope (issue #687):** #638 scoped *storage*; this scopes *behavior*. Orchestration skills (`/pm`, `/pm-handoff`, siblings) read the whole state file through `session-state.sh --session-view` — a repo-scoped projection (this repo's `.prs`/`.root_repo` + only its `.active_agents`; other repos dropped) resolved by the same precedence — **never `--get .`**, which aggregates every repo and is the cross-repo leak. Default output stays in the invoking repo's lane; cross-repo reporting is opt-in via `--session-view --all-repos`. Never *offer or perform* a write (cleanup/merge/rebase/close) against a PR/issue outside the invoking repo.

Update `session-state.json` on phase transitions and key events (agent launched/completed, review received, dropped poll recovered). **All writes go through `.claude/scripts/session-state.sh --set <jq-path>=<value>`** (read with `--get`); it preserves siblings, writes atomically, and holds the lock below.

**Write lock (issue #639):** `session-state.sh` serializes the whole read-modify-write cycle, not just the `mv`, via `.claude/scripts/state-lock.sh` (portable `mkdir` lockdir; macOS has no `flock(1)`). Unserialized, concurrent writers silently lost each other's changes. `greptile-budget.sh` and `cr-review-hourly.sh` source the same library. A writer that can't acquire the lock (30s default, `CLAUDE_STATE_LOCK_TIMEOUT`) exits **6** having written nothing — treat 6 as "unchanged, retry". Dead-holder locks self-heal; reads don't lock. Failure modes: `state-lock.sh`'s header.

**Scoping is not retroactive (issue #651):** #638's migration attributes a legacy entry by its own `owner_repo`, else by its recorded `root_repo` when that path still resolves — legacy entries usually have neither, so they land in `_unknown`, which `infer-pr.sh` and `pr-state.sh` merge into *every* repo's candidates (so the collision persists there) while `--session-view` hides it. Repair with `.claude/scripts/session-state-audit.sh` — read-only by default; `--apply --reattribute` moves entries by verified commit SHA, `--prune` drops long-merged ones but withholds any carrying unactioned `wrap_sweep.needs_decision` notes. Backs up first, holds the lock, re-checks integrity.

**Field-type contract (issue #625):** `session-state.sh` enforces expected JSON types on known fields (`active_agents`, `prs`, per-PR nested fields per #640, and each repo scope per #638): a `--set` storing the wrong type is rejected (exit 4, file unmodified); a `--get` on a corrupted field warns and returns a safe default so the next validated write self-heals. **Never pass a raw jq filter as a `--set` value** — evaluate it locally first and pass the resulting JSON. Full contract: `session-state.sh`'s header comment (single source of truth).

## Handoff File Storage

- **Location:** `~/.claude/handoffs/` (create if missing: `mkdir -p ~/.claude/handoffs/`)
- **Naming:** `pr-{N}-handoff.json` (e.g., `pr-618-handoff.json`)
- **One file per PR at any time.**
- **Known gap (issue #655):** this name is still global, so two repos at one PR number share a file — the cause of "pr-84-handoff.json exists but PR #84 does not resolve in this repo". Scoped out of #638 deliberately: renaming it touches every protocol, script, and skill hard-coding the name.
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

