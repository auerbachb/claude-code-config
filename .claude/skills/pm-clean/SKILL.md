---
name: pm-clean
description: Scan open issues for staleness and suggest closures. Detects issues solved by merged PRs, no-activity issues (30+ days), superseded issues, and potential duplicates of already-closed issues. Presents recommendations for user confirmation — never auto-closes. Triggers on "pm-clean", "stale issues", "clean backlog", "close stale".
argument-hint: "[days] (optional — inactivity threshold, default 30)"
---

Scan the repo's open issues for staleness and present closure recommendations. Parse `$ARGUMENTS`:

- If `$ARGUMENTS` is a number, use it as the inactivity threshold in days.
- If empty or non-numeric, default to 30 days (warn if non-numeric: "Invalid argument '{value}', defaulting to 30 days").

## Step 1: Gather open issues

Fetch all open issues:

```bash
gh issue list --state open --limit 500 --json number,title,labels,assignees,createdAt,updatedAt,body
```

Store the result. If the list is empty, report "No open issues found — backlog is clean." and stop.

Record the total count for the summary.

## Step 2: Gather recently merged PRs

Fetch merged PRs to cross-reference closure keywords:

```bash
gh pr list --state merged --limit 200 --json number,title,body,mergedAt,headRefName
```

## Step 3: Gather recently closed issues (for duplicate detection)

```bash
gh issue list --state closed --limit 200 --json number,title,body,closedAt,stateReason
```

## Step 4: Detect issues solved by merged PRs

For each merged PR from Step 2, scan the PR body AND branch name for closure keywords referencing open issues:

**In the PR body**, search for these patterns (case-insensitive):
- `Closes #N`, `Close #N`
- `Fixes #N`, `Fix #N`
- `Resolves #N`, `Resolve #N`

Extract each referenced issue number `N`. If `N` matches an open issue from Step 1, flag it:
- **Category:** `solved-by-pr`
- **Rationale:** "PR #M (`title`) merged on `date` references `Closes #N` but issue remains open."

**In the branch name**, search for patterns like `issue-42-` or `42-` at the start. If the branch name contains a number matching an open issue and the PR merged successfully, flag it as a weaker signal:
- Only flag if the PR title or body shares at least 2 significant keywords with the open issue's title (after lowercasing and removing stopwords like "add", "fix", "update", "the"). This avoids false positives from coincidental branch numbering.

## Step 5: Detect inactive issues

For each open issue from Step 1, check for recent activity:

1. **Last update check:** Compare `updatedAt` against the inactivity threshold. If `updatedAt` is older than the threshold, the issue is a candidate.

2. **Comment check (for candidates only):** For issues that pass the updatedAt filter, verify by fetching comment timestamps. Replace `{owner}`, `{repo}`, and the issue number with actual values:
   ```bash
   # Example for issue #42 — check if any comments fall within the threshold
   gh api "repos/{owner}/{repo}/issues/42/comments" --jq '[.[] | .created_at] | sort | last'
   ```
   If the most recent comment is older than the threshold (or there are no comments), the issue is still a candidate.

   If the jq result is `null` (empty comments array), treat it as "no recent comments" — the issue remains a candidate.

   Also check if any open PR references this issue (substitute the issue number into the regex):
   ```bash
   gh pr list --state open --json number,title,body --jq '.[] | select(.body | test("(?i)(closes|fixes|resolves)\\s+#42"))'
   ```

3. **If no comments in the threshold period AND no open PR references the issue**, flag it:
   - **Category:** `inactive`
   - **Rationale:** "No activity for X days (last updated: `date`). No open PRs reference this issue."

4. **If the issue has comments but all are older than the threshold**, still flag but note the last comment date.

**Performance note for large backlogs:** If there are more than 50 inactive candidates after the `updatedAt` filter, limit the per-issue API calls (comment check + PR reference check) to the 50 oldest issues. Note the remaining count: "N additional inactive issues not fully checked — run again with a shorter threshold to review them."

## Step 6: Detect superseded issues

For each open issue from Step 1 (that wasn't already flagged in Steps 4-5), check if the issue's context has been overtaken by recent changes:

1. **Extract file references** from the issue body — look for paths like `src/foo.ts`, `lib/bar.py`, function names, or component names.

2. **For issues with file references**, check if those files have been substantially changed since the issue was created. Replace `ISSUE_CREATED_DATE` with the issue's `createdAt` value (ISO date, e.g., `2026-01-15`) and `path/to/file` with the actual file path:
   ```bash
   git log --since="2026-01-15" --oneline -- "src/utils/parser.ts"
   ```
   If the file has 5+ commits since the issue was created, it's a superseded candidate.

3. **For issues referencing features or behaviors**, check if the described feature was added or removed by scanning recent commit messages. Replace `KEYWORD` with a key term extracted from the issue (e.g., a feature name or component):
   ```bash
   git log --since="2026-01-15" --oneline --grep="dark mode"
   ```

4. **Only flag if the evidence is strong** — multiple commits touching the referenced files/features. A single commit is not enough (it might be an unrelated refactor).
   - **Category:** `superseded`
   - **Rationale:** "Files referenced in this issue (`path`) have been modified in N commits since the issue was created. The described behavior may already be addressed."

## Step 7: Detect potential duplicates

Compare each open issue's title and body against closed issues from Step 3:

1. **Title similarity:** Normalize titles (lowercase, strip punctuation, remove common words like "add", "fix", "update", "the", "a"). If two titles share 3+ significant words, they're a candidate pair.

2. **Body keyword overlap:** Extract key terms from both issue bodies (ignoring markdown formatting, code blocks, and boilerplate). If 5+ significant terms overlap, strengthen the duplicate signal.

3. **Only flag if the closed issue was resolved** (not closed as "not planned"):
   - **Category:** `potential-duplicate`
   - **Rationale:** "Similar to closed #M (`title`, closed `date`). Shared keywords: `word1, word2, word3`."

4. **Do not flag issues that reference each other** — if an open issue says "follow-up to #M" or "related to #M", it's intentionally separate, not a duplicate.

## Step 8: Present recommendations

Group all flagged issues by category and present them in a scannable format.

### Output structure

```
## Backlog Cleanup Recommendations

Scanned N open issues. Found M candidates for closure.

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
- **Handle large backlogs gracefully.** If there are 100+ open issues, batch the API calls and use the performance limits described in Step 5. Report how many issues were fully analyzed vs. skimmed.
- **Respect issue labels.** If an issue has labels like `pinned`, `do-not-close`, `long-term`, or `epic`, skip it in the inactive and superseded checks. Still check it for solved-by-PR (since that's a factual signal, not a judgment call).
- **When the user confirms closures**, close each issue with a comment:
  ```bash
  # Replace 42 with the actual issue number and customize the rationale
  gh issue close 42 --comment "Closing: [rationale from the recommendation]. Identified by backlog cleanup scan."
  ```
