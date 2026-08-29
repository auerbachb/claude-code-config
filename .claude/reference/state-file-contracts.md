# State File Contracts — Scoping, Locking, Migration, Types

Expanded mechanism and rationale for `~/.claude/session-state.json` and `~/.claude/handoffs/`. The binding rules live in `.claude/rules/handoff-files.md`; this file carries the "why it works this way" detail that does not need to be in the auto-loaded corpus.

Canonical contracts are the script headers themselves — `session-state.sh --help`, `handoff-state.sh --help`, `state-lock.sh` header. When this file and a script header disagree, the header wins.

## Repo scoping (issue #638)

Session state lives at `.repos["<owner>/<name>"].prs["<N>"]` rather than a flat `prs` map. For the full resolution-priority narrative and migration behavior, see the `session-state.sh --help` header (REPO SCOPING section). The short form:

1. an explicit `--repo owner/name`
2. `$CLAUDE_SESSION_REPO`
3. the origin remote of the current working directory

Entries that predate scoping and cannot be attributed land under `_unknown`. Account-level fields (Greptile daily budget, CodeRabbit hourly consumption) stay global — they are per-account quotas, not per-repo state.

### Polling-gate scope resolver boundary (issue #971)

`.claude/scripts/lib/pr-scope-resolver.sh` is the single home for the repo-identity
and per-PR scope-resolution seam used by `polling-state-gate.sh`. The entry point
still owns argument parsing, mode dispatch, and the `--repo` / `--root-repo` /
inherited `$CLAUDE_SESSION_REPO` precedence override; it hard-fails if the library
cannot be sourced so the correctness-sensitive logic cannot drift into a fallback
copy.

The library preserves two mechanisms because they answer different questions:

- `resolve_pr_scope()` decides **which state lane to read**: the active repo's
  `.repos["<owner>/<name>"]` lane, then legacy `_unknown`, never another named
  repo that happens to hold the same PR number (issue #638).
- `repo_identity()` and `validate_root_match()` decide **whether the invoking
  checkout may act on that lane** by comparing normalized repo identity and the
  per-PR `owner_repo` / `root_repo` fields (issue #647).

All state reads in this library go through `session-state.sh`; it never opens or
writes `session-state.json` or handoff JSON directly. State mutation remains with
`session-state.sh`, handoff mutation with `handoff-state.sh`, and polling watermark
mutation with `poll-watermarks.sh`, preserving each helper's lock and path
contract.

### Polling-gate protection against inherited scope leakage (issue #967)

`polling-state-gate.sh` resolves the invoking checkout before applying that
general helper precedence. Without an explicit `--repo`, a checkout whose
`origin` yields a real `owner/repo` replaces any inherited
`$CLAUDE_SESSION_REPO`, then re-exports the resolved identity so
`session-state.sh`, `poll-watermarks.sh`, and later child helpers all agree. An
inherited value is retained only as a supply-only fallback for an origin-less
checkout (or another checkout that cannot identify itself). An explicit
`--repo` remains a declaration and is refused when it contradicts the invoking
checkout. `statusline.sh` established the earlier instance of defending reads
from stale inherited repo scope; the gate keeps the fallback because it also
supports origin-less checkout operation.

This prevents new writes from landing in the wrong scope; it does not migrate
old entries. `session-state-audit.sh --apply --reattribute` remains the
downstream housekeeping command for entries that can be identified under
`_unknown`; `--apply --prune` handles old closed entries once they meet its
retention and notes safeguards. Neither operation moves an active entry out of
an already named but incorrect scope, so that case still requires targeted
correction rather than being part of this gate fix.

Issue #655 addressed a distinct, earlier occurrence of the "resolve by PR
number before scoping" anti-pattern by moving handoffs into per-repo
directories. No handoff change is required for issue #967. This repository,
`auerbachb/claude-code-config`, is the source of the gate scripts, so the fix
belongs here even though the faulty behavior was first observed from another
repository.

## Scope-key case normalization (issue #704)

The `.repos["<owner>/<name>"]` key is **always lowercase**, and handoff directories `~/.claude/handoffs/{owner}/{repo}/` follow the same contract.

Three independent code paths derive this key:

- `session-state.sh` — `repo_key_from_remote_url()` and `resolve_repo_key()`
- `polling-state-gate.sh` via `lib/pr-scope-resolver.sh` — `repo_identity()`
- `handoff-state.sh` — the path resolver

Before #704 each normalized differently, so a mixed-case remote URL (`AuerbachB/Skingod`) and its lowercase form (`auerbachb/skingod`) mapped to two different scopes — the same PR appeared to be two PRs depending on which script wrote last. All three now share one normalizer, `lib/repo-normalizer.sh`.

Every live key was already lowercase when the normalizer landed, so the change is backward-compatible with no migration step.

## Invoking-repo scope (issue #687)

Orchestration skills read repo-scoped projections via `session-state.sh --session-view`. Using `--get .` instead aggregates every repo in the state file, which leaks other projects' PRs into a status table or, worse, into a merge decision.

Cross-repo reporting is opt-in: `--session-view --all-repos`. Write operations (merge, rebase, close) against a PR outside the invoking repo are never permitted, regardless of projection.

This is the repo-dimension analog of the authorship guard (`.claude/reference/authorship-guard.md`, issue #733): scope by *where*, scope by *whose*.

## Write locks (issues #639, #682)

`state-lock.sh` implements mutual exclusion with a portable `mkdir`-based lockdir. For the full rationale, see the `state-lock.sh` header (WHY mkdir AND NOT flock(1) section).

- **#639** — `session-state.sh` serializes all reads and writes through it. `greptile-budget.sh` and `cr-review-hourly.sh` share the same library, so budget accounting cannot race an orchestration write.
- **#682** — handoff writes go through `handoff-state.sh`, using the same lock library.

Both exit **6** on lock timeout; the caller retries. Locks whose holder process has died self-heal on the next acquisition attempt rather than wedging the session.

The reason inline `jq … > tmp && mv tmp` is banned is that it is atomic with respect to the *file* but not with respect to the *lock* — it will happily clobber a concurrent writer's siblings.

## `HOME` unset — exit 8 (issue #1434)

`session-state.sh` and `reviewer-of.sh` resolve their state file from `$HOME`. When `HOME` is unset there is no state file to resolve, so both exit **8** with a single named stderr line (`HOME is unset; cannot resolve ~/.claude/session-state.json`) instead of aborting with bash's `HOME: unbound variable` under `set -u`. `silence-watchdog.sh` and `script-usage-report.sh` use the same code for the same condition on their own `~/.claude` paths.

Like the lock-timeout **6** above, 8 is a fresh number rather than an overload of the existing 2–7 vocabulary, so a caller can tell "no HOME in this environment" from a usage error (2) or a genuine I/O failure (5).

Two properties callers can rely on:

- **Cheap paths never require `HOME`.** `--help`, every usage error, and `session-state.sh --repo-key` answer before the guard — none of them open the state file. Exit 8 means a mode that genuinely needed `~/.claude` was reached.
- **No fabricated paths.** There is deliberately no `${HOME:-}` fallback anywhere on a load-bearing path: an empty default would produce root-anchored `/.claude/...` paths and strew state at the filesystem root — the stray-file hazard issue #1430 removed. The guard fails fast instead. The non-load-bearing usage-telemetry append is separate: it is skipped entirely when `HOME` is unset, and never changes any script's exit contract.

Pinned by `.claude/scripts/tests/unset-home-contract.test.sh` (all four scripts) and the unset-`HOME` block in `session-state.test.sh` (per-mode).

## Scoping is not retroactive (issue #651)

Adding scoping did not rewrite entries already on disk. Legacy entries lacking `owner_repo` / `root_repo` stay in `_unknown`, where they still collide in `infer-pr.sh` and `pr-state.sh` candidate lists.

Repair with `session-state-audit.sh --apply --reattribute`, which moves entries into their correct scope by matching HEAD SHA. `--prune` additionally drops entries whose PRs are merged. The audit backs the file up first, holds the write lock for the duration, and re-checks integrity afterward.

## Field-type contract (issues #625, #1283)

`session-state.sh` enforces JSON types on known fields:

- a `--set` **or `--cas`** carrying the wrong type exits **4** and leaves the file unmodified
- a `--get` against a corrupted field warns and returns a type-appropriate safe default

Both write paths run the identical check, through one shared
`enforce_field_type_contract()`, against the candidate document and before the
atomic `mv` — so no value is acceptable through one path and rejected through
the other (issue #1283 closed that gap; `--cas` previously skipped the check
entirely). For `--cas` the check runs only after the compare succeeds, so a
type violation (**4**) stays distinct from a lost race (**7**).

The most common way to corrupt a field is passing a raw jq filter as a `--set` value — the string is stored literally instead of being evaluated. Evaluate first, then pass the resulting scalar.

`handoff-state.sh` has no field-type schema, so it cannot run the check above. It does refuse the clearest form of that same mistake (issue #1357): a `--set` value that starts like a jq path expression, carries a jq operator, **and** compiles as a jq program exits **4** with the file unmodified, rather than silently clobbering the field with the expression's source text. A value that misses any one of those three signals is still stored verbatim as a string — prose, SHAs, paths and URLs keep working. A value containing `#` or `;` skips the compile probe outright and stores as a string: either character can carry the value past the probe's terminator and get its tail executed during what is meant to be a compile-only check (a `#` comment swallowing the terminator, or a trailing unterminated `def` absorbing it), so the guard declines to judge those rather than risk running them. `--append` is deliberately outside that guard: its values are array elements and cannot overwrite a prior value. The script header stays the canonical contract.

The `_field_types.top_level` and `_field_types.pr_nested` maps in
`session-state-schema.json` are the single source of truth for which fields are typed and what
each type is. `session-state.sh` and `session-state-audit.sh` load those maps at runtime; their
headers describe the mechanism without carrying a second field inventory.

The remainder of `session-state-schema.json` is the canonical representative state document. It
keeps field shapes, compatibility examples, and lifecycle vocabulary next to the type contract.
Focused tests may assert important values in that representative document—for example, Monitor
identity and teardown semantics in `scheduling-primitive-alignment.test.sh`. It is intentionally
not a disposable sample.

### Adding or changing a session-state field

1. Add the field to `_field_types` only when `session-state.sh` must enforce a specific JSON type.
   Untyped fields need no schema-map edit and remain forward-compatible.
2. Update the representative document when the field's shape is part of the cross-agent contract.
3. Add or update a focused alignment test when a lifecycle term, identity pair, or related group
   of fields must change together.
4. Document rationale and migration detail here. Do not copy the complete typed-field list into a
   script header, rule, skill, or another reference file.

Sub-shape documents may explain their own state machines without becoming schema owners.
`merge-sequencing.md` owns merge-hold behavior, and `/babysit-pr` owns its Monitor lifecycle; the
JSON field names and enforced types remain authoritative in `session-state-schema.json`.

## Handoff file migration

The legacy flat layout `~/.claude/handoffs/pr-{N}-handoff.json` is preserved for compatibility. `handoff-migrate.sh --apply` moves flat files into the scoped `{owner}/{repo}/` layout.

Per-repo scoping (issue #655) is what makes "one file per PR" true in the presence of multiple repos — two repos at PR #42 previously fought over one path.

Resolve the canonical path for any PR with:

```bash
.claude/scripts/handoff-state.sh --owner-repo <owner>/<repo> --path <N>
```

`handoff-state.sh --owner-repo <owner>/<repo> --create` calls `mkdir -p` on the subdirectory automatically, so callers never need to pre-create it.

## Backoff schema fields consumed by `polling-backoff-warn.sh` (issue #794)

The hook reads three groups of fields from `.prs["<N>"]` to enforce the stable-state backoff ladder without re-emitting a widen/stop that was already applied.

**`last_cron_action`** — object, written by the agent after each CronCreate/CronUpdate/CronDelete:

| Sub-field | Type | Values |
|-----------|------|--------|
| `.type` | string | `"create"` / `"update"` / `"delete"` |
| `.interval` | string | e.g. `"1m"` / `"5m"` / `"15m"` / `"paused"` |
| `.at` | string | ISO-8601 UTC timestamp of the action |

The hook skips re-emitting a widen instruction when `.type == "update"` and `.interval` already equals the computed widened value (`${WIDE_MIN}m`). It skips the stop instruction when `.type == "delete"`. Field names `action`/`to_minutes` (written before this schema was documented) caused the hook to keep firing — always use the names above.

**`babysit.cadence_base_minutes`** — number, set by `/babysit-pr` arm mode from the `--cadence` argument (default `5`). The hook reads this to compute `WIDE_MIN = max(15, 3 × base)`. When absent or unparseable the hook defaults to `5`, matching the skill default.

**`babysit.cadence_effective_minutes`** — number, updated by `/babysit-pr` T5 whenever the effective cadence crosses a tier boundary. Informational; the hook does not read it (it derives the widened value from `cadence_base_minutes` directly).

## Diff-survival snapshot — deliberately outside these mechanisms (issue #757)

`diff-survival-check.sh` persists one file at `git rev-parse --git-path claude-diff-survival.json` — `.git/claude-diff-survival.json` in the main worktree, `.git/worktrees/<name>/claude-diff-survival.json` in a linked one. It is **not** session state and **not** a handoff file: it is written and read only by `diff-survival-check.sh`, scoped to a single worktree's in-flight rebase/merge rather than to a PR or a session, untracked, and transient — deleting it (or running `diff-survival-check.sh clear`) costs nothing but the ability to verify the current resolution. It lives in the git dir precisely so it survives a session being killed mid-rebase, which is the scenario it exists for. Full rationale: `.claude/reference/diff-survival-guard.md`.
