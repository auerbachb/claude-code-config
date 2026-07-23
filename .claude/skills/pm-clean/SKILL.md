---
name: pm-clean
description: Scan two independent fronts and recommend cleanup — open GitHub issues (solved-by-PR, inactive, superseded, duplicates) and the on-disk workspace (stale worktrees + local/remote branches, via the shared stale-cleanup.sh). Never auto-closes issues or deletes worktrees/branches without confirmation. Triggers on "pm-clean", "stale issues", "clean backlog", "close stale", "clean worktrees", "stale branches", "prune branches".
argument-hint: "[days] (optional — default 30; applies to issue inactivity and worktree/branch age) [--worktree-days N] (optional — override worktree/branch age only)"
---

`/pm-clean` is the repo's single janitor. It runs two **independent** staleness scans and presents one recommend-then-confirm report:

1. **Open GitHub issues** — solved-by-merged-PR, inactive, superseded, potential duplicates.
2. **On-disk workspace** — stale worktrees and stale local/remote branches, via `.claude/scripts/stale-cleanup.sh` (the exact script `/pm-update` Step 8 calls — one implementation, no divergence).

The two scans never gate each other: one finding nothing does **not** suppress the other, and the summary always reports both. Nothing is closed or deleted without explicit confirmation.

> **Invoking-repo scope (issue #687).** Both scans stay in the invoking repo's lane:
> the issue scan (`backlog-staleness.sh`) runs `gh issue list` cwd-repo-scoped, and
> the workspace sweep (`stale-cleanup.sh`) enumerates worktrees/branches via
> `git -C "$ROOT"` where `$ROOT` is *this* repo's root — never another project's
> worktrees. `/pm-clean` therefore never offers to close an issue or delete a
> worktree/branch outside the invoking repo, whether run directly or inline from `/pm`.

## Step 0: Parse arguments

Parse `$ARGUMENTS`:

- **`[days]`** — the first bare (non-flag) token. If it is a positive number, use it as the issue-inactivity threshold **and** the default worktree/branch age. If empty, non-numeric, or non-positive (zero or negative), default to 30 days:
  - Warn if non-numeric: "Invalid argument '{value}', defaulting to 30 days"
  - Warn if non-positive: "Threshold must be positive, defaulting to 30 days"
- **`--worktree-days N`** — optional flag. If present and a positive integer, it overrides the worktree/branch age **only** (the issue scan still uses `[days]`). If present but invalid (non-numeric or non-positive), warn ("Invalid --worktree-days '{value}', reusing the [days] threshold of {DAYS}") and fall back to `[days]`. If the flag is absent, the worktree/branch age reuses `[days]`.

Record two values for the rest of the run: `DAYS` (issue-inactivity threshold) and `WORKTREE_DAYS` (workspace threshold — equal to `DAYS` unless `--worktree-days` overrode it).

> **Threshold note.** Reusing `[days]` means `/pm-clean` defaults the workspace age to 30 days (its issue default), whereas `/pm-update` Step 8 keeps its own `STALE_DAYS=7` default. That is intentional: the two skills share the *implementation* (`stale-cleanup.sh`), not the threshold. Use `--worktree-days 7` for the aggressive sweep.

## Step 1: Issue staleness scan

> **Authorship guard (issue #733, `safety.md`).** `/pm-clean` performs **no PR writes** — it closes issues (after confirmation) and cleans local worktrees/branches; it never merges, comments on, or closes a PR. Any merged-PR data it reads (e.g. "solved by merged PR") is **read-only context**, and may legitimately reference a collaborator's PR. Workspace cleanup already protects **every** open PR's branch (yours and collaborators') from deletion via `stale-cleanup.sh`, so no author filter is applied there by design.

### Step 1.1: Count the open backlog

```bash
gh issue list --state open --limit 500 --json number | jq 'length'
```

Record the count as `TOTAL_OPEN` for the summary. If it is 0, the issue backlog is clean — note that for Step 3, but **do not stop**: continue to the workspace scan (Step 2). The two scans are independent.

### Step 1.2: Run the shared staleness detection

```bash
.claude/scripts/backlog-staleness.sh --days <DAYS> --json
```

This one call reproduces what was previously four separate inline steps here — gathering open issues, merged PRs, and closed issues, then flagging **solved-by-merged-PR** (closing-keyword regex in merged PR bodies, plus a weaker branch-name signal requiring 2+ shared keywords), **inactive** (the `updatedAt` threshold plus a per-issue comment/open-PR-reference/commit-reference triple check, capped at the 50 oldest candidates), **superseded** (issue-body file/keyword references with 3+ commits each, or 5+ commits on a single file), and **potential-duplicate** (3+ shared significant title words against a *resolved* closed issue, suppressed by explicit cross-references).

Since issue #656 `/pm` runs this entire `/pm-clean` flow inline by default (reversing the #598 count-only design; the only opt-out is `/pm`'s `--no-clean` / `fast` ranking-only flag), so it reaches `backlog-staleness.sh` through this same flow rather than a separate call — both skills share the one `backlog-staleness.sh` detector, so the detection logic cannot diverge between them. Full per-category rules, safeguards (the `pinned`/`do-not-close`/`long-term`/`epic` label-skip, the 50-candidate performance cap), and the JSON record shape are documented in `.claude/scripts/backlog-staleness.sh --help`.

Each returned record has `number`, `title`, `category` (`solved-by-pr`|`inactive`|`superseded`|`potential-duplicate`), a human-readable `rationale`, plus category-specific evidence fields (`pr`/`merged_at`; `last_activity`/`age_days`; `path`/`commits`; `closed_issue`/`closed_title`/`closed_at`/`keywords`). Group records by `category` for Step 3.

## Step 2: Workspace staleness sweep (worktrees + branches)

This scan delegates **entirely** to `.claude/scripts/stale-cleanup.sh` — the same script `/pm-update` Step 8 calls (issue #618). **Reuse it as-is: never re-derive worktree/branch detection, thresholds, or safety checks in this skill.** The script's safety contract is the single source of truth — it always skips the main worktree, your current worktree, worktrees with uncommitted tracked changes, open-PR branches, protected branch names, and branches checked out in a worktree. See `.claude/scripts/stale-cleanup.sh --help` for the full contract.

### Step 2.1: Run the dry-run pass

Always run `--check` first — the script never deletes in this mode. Pass the resolved threshold via `STALE_DAYS`, and capture both the JSON and the exit code:

```bash
RC=0
WORKSPACE_JSON="$(STALE_DAYS="$WORKTREE_DAYS" .claude/scripts/stale-cleanup.sh --check --json)" || RC=$?
```

The `|| RC=$?` guard is required: `--check` exits **1** when stale items exist (the normal "found something" case), which would otherwise abort this step under `set -e`.

Branch on `RC` (same contract as `/pm-update` Step 8):

- **`RC == 0`** — no stale items. Record "no stale worktrees or branches" for the Step 3 summary.
- **`RC == 1`** — stale items exist. Parse `WORKSPACE_JSON` and present them in Step 3.
- **`RC == 3`** — usage error (bad flag or `STALE_DAYS`). Surface the script's `--help` output and skip the workspace section — this indicates a bug in this skill's invocation, not a real-state problem. The issue scan (Step 1) still stands.
- **`RC == 4`** — environment error (no `gh`/`jq`, cannot resolve repo). Surface stderr and skip the workspace section. The issue scan still stands.
- **Any other exit** — treat like an environment error: surface stderr and skip the workspace section (the issue scan still stands). `--check` documents only 0/1/3/4, so this is a defensive catch-all.

`WORKSPACE_JSON` shape (from `--check --json`): `root` (the resolved main-worktree root of the swept repo — cwd-derived, or `--root` when passed; issue #707); `stale_days`; `stale_worktrees[]` (`path`, `branch`, `last_commit_ts`); `stale_local_branches[]` (`branch`, `last_commit_ts`); `stale_remote_branches[]` (`ref`, `last_commit_ts`); and `skipped_worktrees[]` / `skipped_local_branches[]` / `skipped_remote_branches[]` (each `{…, reason}`). Every key is always present (empty arrays when nothing matches), so parsing is safe regardless of state. `last_commit_ts` is a Unix timestamp — render it as `YYYY-MM-DD` for display (`date -r <ts> +%F` on macOS/BSD, `date -d @<ts> +%F` on GNU — the same portable pair `stale-cleanup.sh` uses internally).

## Step 3: Present combined recommendations

Present **both** scans in one report — issue sections first, then workspace sections. Omit any category that has no items; when an entire scan finds nothing, emit its one-line "clean" note (never stay silent about a scan that ran).

### Issue sections

Group flagged issues by `category` and present them in a scannable format:

```
## Backlog Cleanup Recommendations

Scanned {TOTAL_OPEN} open issues. Found M candidates for closure.

### Solved by Merged PR (K issues)

These issues appear to have been resolved by merged PRs but were not auto-closed:

| Issue | PR | Merged | Recommendation |
|-------|-----|--------|----------------|
| #N — Title | PR #M | date | Close — PR body contains `Closes #N` |

### Inactive (K issues, threshold: X days)

No activity (comments, PR references, or updates) in X+ days:

| Issue | Last Activity | Age | Recommendation |
|-------|--------------|-----|----------------|
| #N — Title | date | X days | Close with comment or reassign |

### Superseded (K issues)

Referenced files/features have been substantially modified since issue creation:

| Issue | Evidence | Recommendation |
|-------|----------|----------------|
| #N — Title | N commits to `path` since creation | Verify resolved, then close |

### Potential Duplicates (K pairs)

Open issues that may duplicate already-closed issues:

| Open Issue | Similar Closed Issue | Shared Keywords |
|-----------|---------------------|-----------------|
| #N — Title | #M — Title (closed date) | word1, word2, word3 |
```

Populate each row directly from the record's fields — `pr`/`merged_at` (Solved by Merged PR), `last_activity`/`age_days` (Inactive), `path`/`commits` (Superseded), `closed_issue`/`closed_title`/`closed_at`/`keywords` (Potential Duplicates). The `Recommendation` column is authored prose (e.g. "Close — PR body contains a closing keyword"), not a script field — `rationale` is the evidence backing it, useful as a one-line justification if a table gets flattened to a list.

If a category has no flagged issues, omit that section entirely. If no issues were flagged across all categories, state: "Issue backlog is clean — no stale or duplicate issues detected." (Do not stop — the workspace section still follows.)

### Workspace sections

Render from `WORKSPACE_JSON` (only when `RC == 1`). Convert each `last_commit_ts` to a `YYYY-MM-DD` date. Put the item count in each heading, and omit any category with no items:

```
### Stale Worktrees (K)

Idle {WORKTREE_DAYS}+ days. Removing a worktree also deletes its branch when that branch is unprotected and has no open PR.

| Worktree | Branch | Last Commit | Recommendation |
|----------|--------|-------------|----------------|
| `path` | `branch` | date | Remove — idle {WORKTREE_DAYS}+ days |

### Stale Local Branches (K)

| Branch | Last Commit | Recommendation |
|--------|-------------|----------------|
| `branch` | date | Delete — idle {WORKTREE_DAYS}+ days |

### Stale Remote Branches (K)

| Remote Branch | Last Commit | Recommendation |
|---------------|-------------|----------------|
| `origin/branch` | date | Delete — idle {WORKTREE_DAYS}+ days |

### Skipped (safety) (K)

Protected by the script — listed for transparency, NOT offered for deletion:

| Item | Type | Reason |
|------|------|--------|
| `path / branch / ref` | worktree / local branch / remote branch | reason (verbatim from the script) |
```

Draw the **Skipped (safety)** rows from the three `skipped_*` arrays (each item's `reason` verbatim), and render the block whenever any is non-empty while presenting stale items. If the workspace scan found no stale items (`RC == 0`), skip these tables and state: "No stale worktrees or branches detected."

**Summarize the tail.** For large sets (e.g. 20+ stale worktrees), list the most relevant items and summarize the remainder ("…and N more, all idle {WORKTREE_DAYS}+ days") — the same tail treatment the issue scan relies on (`backlog-staleness.sh` caps its own deep check at the 50 oldest candidates and notes any remainder on stderr; surface that note when present).

### Combined summary

Close the report with a one-line status for **each** scan so neither is ambiguous — e.g. "Backlog: 3 closure candidates · Workspace: 5 stale worktrees, 2 stale branches", or, on a fully clean repo, "Backlog is clean · No stale worktrees or branches."

## Step 4: Confirm and act — two separate gates

Issue closures and workspace deletions are **separate** confirmations. Declining one never affects the other — surface both asks, act only on what the user confirms.

### Step 4.1: Issue closures

```
## Next Steps — Issues

To close recommended issues, confirm which ones to close. I can:
1. Close specific issues with a comment explaining why
2. Close all issues in a category (e.g., all "Solved by Merged PR")
3. Skip — leave the backlog as-is

Which issues should I close? (List numbers, category names, or "all")
```

When the user confirms closures, close each issue with a comment:

```bash
# Replace 42 with the actual issue number and customize the rationale
gh issue close 42 --comment "Closing: [rationale from the recommendation]. Identified by backlog cleanup scan."
```

### Step 4.2: Workspace deletions

Only if the workspace scan surfaced stale items (`RC == 1`) and the user explicitly confirms. Ask separately, e.g. "Apply the stale workspace cleanup above? (worktrees removed, local + remote branches deleted)". `--apply` removes **every** listed stale item — the script has no per-item selection — so if the user wants to keep any, they decline and handle it manually.

On explicit confirmation:

```bash
APPLY_RC=0
STALE_DAYS="$WORKTREE_DAYS" .claude/scripts/stale-cleanup.sh --apply || APPLY_RC=$?
```

The script re-runs the same detection (state may have changed since the dry-run), re-applies every safety check, then attempts each deletion. Report the `removed:` / `failed:` lines verbatim:

- **`APPLY_RC == 0`** — all deletions succeeded.
- **`APPLY_RC == 2`** — one or more deletions failed; surface the `failed:` lines. Do not retry automatically — some failures (e.g. network errors on remote-branch deletion) need user intervention.

If the user declines, report: "Workspace cleanup: dry-run only — nothing deleted."

## Rules

- **NEVER auto-close issues.** Always present recommendations and wait for user confirmation.
- **NEVER delete worktrees or branches without explicit confirmation.** `/pm-clean` NEVER runs `stale-cleanup.sh --apply` on its own — consistent with the "never auto-close" rule and `/pm-update` Step 8. The `--check` dry-run is the user's only chance to spot a false positive before anything is removed.
- **The two scans are independent.** One finding nothing must not suppress the other; the summary reports both, always.
- **Delegate workspace detection — never reimplement it.** `stale-cleanup.sh` is the shared source of truth for worktree/branch staleness and safety (issue #618, mirroring the shared-detection precedent `backlog-staleness.sh` set in #598). `/pm-update` Step 8 calls the same script, and `/pm` reaches it by running this whole `/pm-clean` flow inline (#656); keep them in sync by changing only the script, never by forking its logic into this skill.
- **Be conservative with "superseded" and "duplicate" flags.** False positives waste the user's time reviewing issues that shouldn't be closed. Only flag when evidence is clear.
- **Include rationale for every recommendation.** The user should be able to evaluate each suggestion without reading the full issue or inspecting the worktree.
- **Handle large backlogs gracefully.** `backlog-staleness.sh` already caps the inactive-candidate deep check at the 50 oldest issues and notes any remainder on stderr — surface that note in the summary when present. Apply the same summarize-the-tail treatment to large workspace result sets.
- **Respect issue labels.** `backlog-staleness.sh` already skips issues labeled `pinned`, `do-not-close`, `long-term`, or `epic` in the inactive, superseded, and duplicate checks (still checking them for solved-by-PR, since that's a factual signal, not a judgment call) — no extra filtering needed here.
