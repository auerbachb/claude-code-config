# State File Contracts — Scoping, Locking, Migration, Types

Expanded mechanism and rationale for `~/.claude/session-state.json` and `~/.claude/handoffs/`. The binding rules live in `.claude/rules/handoff-files.md`; this file carries the "why it works this way" detail that does not need to be in the auto-loaded corpus.

Canonical contracts are the script headers themselves — `session-state.sh --help`, `handoff-state.sh --help`, `state-lock.sh` header. When this file and a script header disagree, the header wins.

## Repo scoping (issue #638)

Session state lives at `.repos["<owner>/<name>"].prs["<N>"]` rather than a flat `prs` map, because two repos routinely have PRs at the same number and a flat map silently merged them.

`session-state.sh` resolves the scope key in priority order:

1. an explicit `--repo owner/name`
2. `$CLAUDE_SESSION_REPO`
3. the origin remote of the current working directory

Entries that predate scoping and cannot be attributed land under `_unknown`. Account-level fields (Greptile daily budget, CodeRabbit hourly consumption) stay global — they are per-account quotas, not per-repo state.

## Scope-key case normalization (issue #704)

The `.repos["<owner>/<name>"]` key is **always lowercase**, and handoff directories `~/.claude/handoffs/{owner}/{repo}/` follow the same contract.

Three independent code paths derive this key:

- `session-state.sh` — `repo_key_from_remote_url()` and `resolve_repo_key()`
- `polling-state-gate.sh` — `repo_identity()`
- `handoff-state.sh` — the path resolver

Before #704 each normalized differently, so a mixed-case remote URL (`AuerbachB/Skingod`) and its lowercase form (`auerbachb/skingod`) mapped to two different scopes — the same PR appeared to be two PRs depending on which script wrote last. All three now share one normalizer, `lib/repo-normalizer.sh`.

Every live key was already lowercase when the normalizer landed, so the change is backward-compatible with no migration step.

## Invoking-repo scope (issue #687)

Orchestration skills read repo-scoped projections via `session-state.sh --session-view`. Using `--get .` instead aggregates every repo in the state file, which leaks other projects' PRs into a status table or, worse, into a merge decision.

Cross-repo reporting is opt-in: `--session-view --all-repos`. Write operations (merge, rebase, close) against a PR outside the invoking repo are never permitted, regardless of projection.

This is the repo-dimension analog of the authorship guard (`.claude/reference/authorship-guard.md`, issue #733): scope by *where*, scope by *whose*.

## Write locks (issues #639, #682)

macOS ships no `flock(1)`, so `state-lock.sh` implements mutual exclusion with an atomic `mkdir` lockdir.

- **#639** — `session-state.sh` serializes all reads and writes through it. `greptile-budget.sh` and `cr-review-hourly.sh` share the same library, so budget accounting cannot race an orchestration write.
- **#682** — handoff writes go through `handoff-state.sh`, using the same lock library.

Both exit **6** on lock timeout; the caller retries. Locks whose holder process has died self-heal on the next acquisition attempt rather than wedging the session.

The reason inline `jq … > tmp && mv tmp` is banned is that it is atomic with respect to the *file* but not with respect to the *lock* — it will happily clobber a concurrent writer's siblings.

## Scoping is not retroactive (issue #651)

Adding scoping did not rewrite entries already on disk. Legacy entries lacking `owner_repo` / `root_repo` stay in `_unknown`, where they still collide in `infer-pr.sh` and `pr-state.sh` candidate lists.

Repair with `session-state-audit.sh --apply --reattribute`, which moves entries into their correct scope by matching HEAD SHA. `--prune` additionally drops entries whose PRs are merged. The audit backs the file up first, holds the write lock for the duration, and re-checks integrity afterward.

## Field-type contract (issue #625)

`session-state.sh` enforces JSON types on known fields:

- a `--set` carrying the wrong type exits **4** and leaves the file unmodified
- a `--get` against a corrupted field warns and returns a type-appropriate safe default

The most common way to corrupt a field is passing a raw jq filter as a `--set` value — the string is stored literally instead of being evaluated. Evaluate first, then pass the resulting scalar.

The `session-state.sh` header is the single source of truth for which fields are typed and what each type is.

## Handoff file migration

The legacy flat layout `~/.claude/handoffs/pr-{N}-handoff.json` is preserved for compatibility. `handoff-migrate.sh --apply` moves flat files into the scoped `{owner}/{repo}/` layout.

Per-repo scoping (issue #655) is what makes "one file per PR" true in the presence of multiple repos — two repos at PR #42 previously fought over one path.

Resolve the canonical path for any PR with:

```bash
.claude/scripts/handoff-state.sh --owner-repo <owner>/<repo> --path <N>
```

`handoff-state.sh --owner-repo <owner>/<repo> --create` calls `mkdir -p` on the subdirectory automatically, so callers never need to pre-create it.

## Diff-survival snapshot — deliberately outside these mechanisms (issue #757)

`diff-survival-check.sh` persists one file at `git rev-parse --git-path claude-diff-survival.json` — `.git/claude-diff-survival.json` in the main worktree, `.git/worktrees/<name>/claude-diff-survival.json` in a linked one. It is **not** session state and **not** a handoff file: it is written and read only by `diff-survival-check.sh`, scoped to a single worktree's in-flight rebase/merge rather than to a PR or a session, untracked, and transient — deleting it (or running `diff-survival-check.sh clear`) costs nothing but the ability to verify the current resolution. It lives in the git dir precisely so it survives a session being killed mid-rebase, which is the scenario it exists for. Full rationale: `.claude/reference/diff-survival-guard.md`.
