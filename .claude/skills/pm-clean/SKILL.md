---
name: pm-clean
description: Scan open issues for staleness and suggest closures. Detects issues solved by merged PRs, no-activity issues (30+ days), superseded issues, and potential duplicates of already-closed issues. Presents recommendations for user confirmation — never auto-closes. Triggers on "pm-clean", "stale issues", "clean backlog", "close stale".
argument-hint: "[days] (optional — inactivity threshold, default 30)"
---

Scan the repo's open issues for staleness and present closure recommendations. Parse `$ARGUMENTS`:

- If `$ARGUMENTS` is a positive number, use it as the inactivity threshold in days.
- If empty, non-numeric, or non-positive (zero or negative), default to 30 days:
  - Warn if non-numeric: "Invalid argument '{value}', defaulting to 30 days"
  - Warn if non-positive: "Threshold must be positive, defaulting to 30 days"

## Step 1: Scan the open backlog

```bash
gh issue list --state open --limit 500 --json number | jq 'length'
```

If the count is 0, report "No open issues found — backlog is clean." and stop. Record the count as `TOTAL_OPEN` for the summary.

## Step 2: Run the shared staleness detection

```bash
.claude/scripts/backlog-staleness.sh --days <threshold> --json
```

This one call reproduces what was previously four separate inline steps here — gathering open issues, merged PRs, and closed issues, then flagging **solved-by-merged-PR** (closing-keyword regex in merged PR bodies, plus a weaker branch-name signal requiring 2+ shared keywords), **inactive** (the `updatedAt` threshold plus a per-issue comment/open-PR-reference/commit-reference triple check, capped at the 50 oldest candidates), **superseded** (issue-body file/keyword references with 3+ commits each, or 5+ commits on a single file), and **potential-duplicate** (3+ shared significant title words against a *resolved* closed issue, suppressed by explicit cross-references).

It is the exact same script `/pm`'s Backlog health block calls (issue #598) — detection results can never diverge between the two skills. Full per-category rules, safeguards (the `pinned`/`do-not-close`/`long-term`/`epic` label-skip, the 50-candidate performance cap), and the JSON record shape are documented in `.claude/scripts/backlog-staleness.sh --help`.

Each returned record has `number`, `title`, `category` (`solved-by-pr`|`inactive`|`superseded`|`potential-duplicate`), a human-readable `rationale`, plus category-specific evidence fields (`pr`/`merged_at`; `last_activity`/`age_days`; `path`/`commits`; `closed_issue`/`closed_title`/`closed_at`/`keywords`). Group records by `category` for Step 3.

## Step 3: Present recommendations

Group all flagged issues by category and present them in a scannable format.

### Output structure

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

If a category has no flagged issues, omit that section entirely.

If no issues were flagged across all categories, report: "Backlog is clean — no stale or duplicate issues detected."

### Closing section

After the recommendations table:

```
## Next Steps

To close recommended issues, confirm which ones to close. I can:
1. Close specific issues with a comment explaining why
2. Close all issues in a category (e.g., all "Solved by Merged PR")
3. Skip — leave the backlog as-is

Which issues should I close? (List numbers, category names, or "all")
```

## Rules

- **NEVER auto-close issues.** Always present recommendations and wait for user confirmation.
- **Be conservative with "superseded" and "duplicate" flags.** False positives waste the user's time reviewing issues that shouldn't be closed. Only flag when evidence is clear.
- **Include rationale for every recommendation.** The user should be able to evaluate each suggestion without reading the full issue.
- **Handle large backlogs gracefully.** `backlog-staleness.sh` already caps the inactive-candidate deep check at the 50 oldest issues and notes any remainder on stderr — surface that note in the summary when present.
- **Respect issue labels.** `backlog-staleness.sh` already skips issues labeled `pinned`, `do-not-close`, `long-term`, or `epic` in the inactive, superseded, and duplicate checks (still checking them for solved-by-PR, since that's a factual signal, not a judgment call) — no extra filtering needed here.
- **When the user confirms closures**, close each issue with a comment:
  ```bash
  # Replace 42 with the actual issue number and customize the rationale
  gh issue close 42 --comment "Closing: [rationale from the recommendation]. Identified by backlog cleanup scan."
  ```
