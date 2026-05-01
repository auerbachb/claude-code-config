---
name: pm-rate-team
description: Evaluate team member contributions over a configurable period (default 2 weeks). Produces per-contributor metrics — PRs merged, review cycles, issue throughput, review participation, and CR success rate — with constructive qualitative observations.
argument-hint: "[--days N] (default: 14)"
---

## Data gathering

This skill uses the canonical query patterns documented in `.claude/reference/pm-data-patterns.md` (time windows, merged PRs, closed issues with closer attribution, review cycles, review participation, bot filtering, first-pass CR success). When updating data collection logic, update the reference doc AND any skills that depend on it.

Evaluate team contributions over a configurable period. Parse `$ARGUMENTS`:

- If `$ARGUMENTS` contains `--days N`, use N days as the evaluation period.
- If empty, default to 14 days.

Extract the value:

```bash
if [[ "$ARGUMENTS" =~ --days[[:space:]]+([0-9]+) ]]; then
  DAYS="${BASH_REMATCH[1]}"
else
  DAYS=14
fi
```

## Step 1: Set evaluation period

```bash
IFS=$'\t' read -r SINCE_DATE SINCE_ISO < <(bash .claude/scripts/gh-window.sh --days "$DAYS")
```

See `.claude/scripts/gh-window.sh` for the ET-anchored, macOS + GNU-compatible date-window builder. `$SINCE_DATE` is `YYYY-MM-DD` (for `gh search` date qualifiers); `$SINCE_ISO` is ISO 8601 with colon-separated offset (for JSON timestamp comparisons).

## Step 2: Load team config (optional)

Extract the `## Team` section via the shared parser:

```bash
TEAM_CONTENT="$(.claude/scripts/pm-config-get.sh --section Team 2>/dev/null)"
TEAM_RC=$?
```

If `TEAM_RC=0`, parse contributor entries from `$TEAM_CONTENT` for display names and roles (same format as `/pm-team-standup` Step 2). Use this for labeling output sections. Otherwise, skip — use GitHub usernames as-is.

## Step 3: Gather data

### 3a: Merged PRs with code volume

```bash
gh pr list --state merged --search "merged:>=$SINCE_DATE" --json number,title,author,mergedAt,additions,deletions,commits --limit 200
```

For each merged PR, record: author, additions, deletions, commit count.

### 3b: Review cycles per PR

For each merged PR from 3a, count review cycles — the number of review rounds that triggered fix commits. Use `--exclude-bots` so human review engagement is measured (bot reviews are tracked separately via first-pass CR success in 3f).

```bash
CYCLES=$(.claude/scripts/cycle-count.sh "$PR_NUM" --exclude-bots)
```

The script counts one cycle per review followed by at least one commit before the next review (or merge). Reviews with no subsequent commits are non-actionable and do not count. Matches the canonical pattern in `.claude/reference/pm-data-patterns.md` "Review cycles per PR". See `.claude/scripts/cycle-count.sh --help` for the full contract.

If no reviews exist on any PR in the period, note this gracefully: "No PR review history found — review cycle metrics skipped."

### 3c: Issue throughput

```bash
# Issues created by each contributor
gh issue list --state all --search "created:>=$SINCE_DATE" --json number,title,author,state,createdAt --limit 500

# Issues closed in the period
gh issue list --state closed --search "closed:>=$SINCE_DATE" --json number,title,closedAt --limit 500
```

**Closer attribution:** The `gh issue list` command does not include a `closedBy` field. To attribute issue closures to contributors, query the events API for each closed issue:

```bash
# For each closed issue number from above (paginate to avoid truncation):
gh api --paginate "repos/{owner}/{repo}/issues/$ISSUE_NUM/events?per_page=100" \
  | jq -r '[.[] | select(.event == "closed")] | last | .actor.login'
```

This returns the GitHub username of the person (or bot) who closed the issue. Attach this `closer` value to each issue record, then compute per-contributor closed counts from the augmented data.

### 3d: Review participation (reviews given to others)

```bash
# Scan PRs active during the evaluation period for reviews (paginate to capture all)
gh api --paginate "repos/{owner}/{repo}/pulls?state=all&sort=updated&direction=desc&per_page=100" \
  | jq -r '.[] | select(.updated_at > "'"$SINCE_ISO"'") | .number' | while read -r pr_num; do
  gh api "repos/{owner}/{repo}/pulls/$pr_num/reviews?per_page=100" \
    --jq '.[] | select(.submitted_at > "'"$SINCE_ISO"'") | select(.user.login | (endswith("[bot]") or . == "github-actions") | not) | {reviewer: .user.login, pr: '"$pr_num"', state: .state}'
done
```

Count reviews per reviewer. Exclude self-reviews (reviewer == PR author).

### 3e: First-pass CR success rate

For each merged PR, check if CodeRabbit's first review passed clean:

1. Fetch the first review from `coderabbitai[bot]` on that PR (sort by `submitted_at`, take the earliest)
2. A PR counts as **first-pass success** when the first `coderabbitai[bot]` review meets BOTH criteria:
   - No inline comments on that first review: `gh api "repos/{owner}/{repo}/pulls/$PR_NUM/reviews/$FIRST_CR_REVIEW_ID/comments?per_page=100"` returns an empty array
   - The first `coderabbitai[bot]` review state is not `CHANGES_REQUESTED`
3. Calculate: (PRs passing CR on first push) / (total PRs with CR reviews) × 100%

If no `coderabbitai[bot]` reviews are found on any PR in the period, skip this metric entirely with a note: "CodeRabbit not detected — CR first-pass rate skipped."

## Step 4: Filter out bots

Exclude accounts ending in `[bot]` and common bot usernames (`dependabot`, `renovate`, `github-actions`) from contributor metrics.

## Step 5: Compute per-contributor metrics

For each human contributor, compute:

| Metric | Calculation |
|--------|-------------|
| PRs merged | Count of merged PRs authored |
| Code volume | Total additions + deletions across merged PRs |
| Avg review cycles | Mean cycles across their merged PRs (lower = cleaner) |
| Issues opened | Count of issues created |
| Issues closed | Count of issues they closed (if attributable) |
| Reviews given | Count of reviews authored on others' PRs |
| CR first-pass rate | % of their PRs that passed CR on first push |

## Step 6: Generate qualitative observations

For each contributor, identify patterns worth noting. Frame these **constructively** — focus on strengths and positive patterns, not weaknesses.

**Pattern detection examples:**
- "Alice's PRs consistently pass CR on first push (90% first-pass rate) — indicates clean, well-tested code"
- "Bob is the primary reviewer for frontend changes (8 of 12 frontend PR reviews)"
- "Carol has the highest issue throughput — opened 15 issues and closed 12, driving backlog refinement"
- "Dave's PRs tend to be large but well-scoped — averaging 400+ lines but only 1.2 review cycles"

**Rules for qualitative notes:**
- Always frame positively or neutrally — never negatively
- Focus on patterns, not isolated incidents
- Note collaboration patterns (who reviews whom, who pairs on related issues)
- If a contributor had low volume, do not call it out — simply show their metrics without commentary
- Do not compare contributors against each other in a ranking — present each person's section independently

## Step 7: Write the report

### Header

```
# Team Contribution Report
Period: {start date} – {end date} ({N} days)
Contributors: {count}
```

### Team summary

```
## Overview

| Metric | Total |
|--------|-------|
| PRs merged | {sum} |
| Code changed | +{adds} / -{dels} ({net} net) |
| Issues opened | {sum} |
| Issues closed | {sum} |
| Reviews completed | {sum} |
```

### Per-contributor sections

For each contributor (sorted alphabetically by display name):

```
## {Display Name} (@username) — {Role if known}

| Metric | Value |
|--------|-------|
| PRs merged | {count} (+{adds} / -{dels}) |
| Avg review cycles | {N} per PR |
| Issues opened / closed | {opened} / {closed} |
| Reviews given | {count} |
| CR first-pass rate | {N}% |

**Observations:** {1-2 sentences noting positive patterns}
```

If a metric is unavailable (e.g., no CR data), omit that row from the table rather than showing "N/A".

### Collaboration patterns (optional)

If the data reveals notable cross-contributor patterns, add a brief section:

```
## Collaboration Patterns

- {Display Name A} and {Display Name B} frequently collaborate — A reviewed 5 of B's PRs
- Frontend PRs are primarily reviewed by {Display Name C}
- Issue creation is concentrated in {Display Name D} — consider distributing backlog grooming
```

Only include this section if genuine patterns emerge from the data. Do not fabricate patterns.

## Writing rules

- **Constructive framing only.** "Low PR count" → omit or reframe as "focused on fewer, larger changes." Never use language that reads as criticism.
- **Metrics are descriptive, not prescriptive.** Present the numbers without judgments like "should be higher" or "needs improvement."
- **Handle sparse data gracefully.** If a contributor has only commits (no PRs, no issues), show what's available. If the repo has no review history at all, skip review-related metrics entirely with a note.
- **Single-contributor repos:** If only one person is found, still produce the report — show their metrics without the team framing. Use "Contribution Report" instead of "Team Contribution Report."
- **Do not fabricate data.** If a metric cannot be computed from available GitHub data, omit it. Never estimate or extrapolate.
- **Keep the report scannable.** Tables for metrics, prose for observations. Total output should be readable in under 3 minutes.
