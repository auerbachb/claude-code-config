---
name: pm-sprint-review
description: Sprint retrospective — what got done, what slipped, velocity metrics, blockers, per-contributor breakdown, and lessons learned. Reuses /pm-rate-team data-gathering approach and pm-config.md for team context.
argument-hint: "[--days N] (default: 14)"
---

Generate a sprint retrospective for the past N days. Parse `$ARGUMENTS`:

- If `$ARGUMENTS` contains `--days N`, use N days as the review period.
- If empty, default to 14 days.

Extract the value:

```bash
if [[ "$ARGUMENTS" =~ --days[[:space:]]+([0-9]+) ]]; then
  DAYS="${BASH_REMATCH[1]}"
else
  DAYS=14
fi
```

## Step 1: Set review period

```bash
IFS=$'\t' read -r SINCE_DATE SINCE_ISO < <(bash .claude/scripts/gh-window.sh --days "$DAYS")
TODAY=$(TZ='America/New_York' date '+%Y-%m-%d')
```

See `.claude/scripts/gh-window.sh` for the ET-anchored, macOS + GNU-compatible date-window builder. `$SINCE_DATE` is `YYYY-MM-DD` (for `gh search` date qualifiers); `$SINCE_ISO` is ISO 8601 with colon-separated offset (for JSON timestamp comparisons).

## Step 2: Load team config (optional)

Check if `.claude/pm-config.md` exists and has a `## Team` section:

```bash
test -f .claude/pm-config.md && echo "CONFIG_EXISTS" || echo "NO_CONFIG"
```

If present, parse contributor entries for display names, GitHub usernames, and roles. Expected format: lines containing `@username` with optional role/description text (e.g., `@alice — Frontend lead`). Use these for labeling output sections. If missing, derive contributors from git activity.

## Step 3: Gather data — what got done

### 3a: Merged PRs

```bash
gh pr list --state merged --search "merged:>=$SINCE_DATE" --json number,title,author,mergedAt,additions,deletions,commits --limit 200
```

For each merged PR, record: number, title, author, merge date, code volume (additions + deletions).

### 3b: Closed issues

```bash
gh issue list --state closed --search "closed:>=$SINCE_DATE" --json number,title,closedAt,labels --limit 200
```

For closer attribution, query the events API for each closed issue:

```bash
gh api --paginate "repos/{owner}/{repo}/issues/$ISSUE_NUM/events?per_page=100" \
  | jq -r '[.[] | select(.event == "closed")] | last | .actor.login'
```

Attach the closer username to each issue record.

### 3c: PR summaries

For each merged PR, read the PR body to understand what the change actually accomplished:

```bash
gh pr view $PR_NUM --json body,title --jq '{title: .title, body: .body}'
```

Extract the business-level summary from the PR body (look for `## Summary` section or the first paragraph). Use the title as fallback.

## Step 4: Gather data — what slipped

### 4a: Identify sprint-start issues

Issues that were open at the start of the review period AND are still open represent slipped work.

```bash
# Issues created before the sprint start that are still open
gh issue list --state open --search "created:<$SINCE_DATE" --json number,title,labels,assignees,createdAt --limit 200
```

The `created:<$SINCE_DATE` filter ensures only pre-sprint issues are returned server-side. These existed when the sprint started — issues created during the sprint are new work, not slippage.

### 4b: Assess slippage

For each slipped issue:
- Check if any PR references it (partially addressed but not closed)
- Check if it has been assigned (work started but not finished)
- Note how old the issue is (stale issues are a different problem than recently-slipped ones)

## Step 5: Velocity metrics

### 5a: Throughput

Count for the review period:
- **PRs merged:** total count and total code volume (additions + deletions)
- **Issues closed:** total count
- **Issues opened:** count of issues created during the period (net throughput = closed - opened)

```bash
gh issue list --state all --search "created:>=$SINCE_DATE" --json number --limit 500 | jq length
```

### 5b: Average cycle time per PR

For each merged PR, compute cycle time: time from PR creation to merge.

```bash
gh pr list --state merged --search "merged:>=$SINCE_DATE" --json number,createdAt,mergedAt --limit 200
```

Calculate `mergedAt - createdAt` for each PR. Report: average, median, min, max.

### 5c: Review cycles per PR

For each merged PR, count review-then-fix rounds (same approach as `/pm-rate-team`). Use `--exclude-bots` so the metric reflects human review engagement:

```bash
CYCLES=$(.claude/scripts/cycle-count.sh "$PR_NUM" --exclude-bots)
```

The script counts one cycle per review followed by at least one commit before the next review (or merge). Reviews with no subsequent commits are non-actionable and do not count. See `.claude/scripts/cycle-count.sh --help` for the full contract and `.claude/reference/pm-data-patterns.md` for the canonical pattern.

Report: average review cycles per PR. Lower is cleaner.

## Step 6: Blockers encountered

Identify PRs and issues that stalled during the sprint:

### 6a: Long-lived PRs

PRs that were open for more than 3 days before merge (or are still open):

```bash
gh pr list --state all --search "created:>=$SINCE_DATE merged:>=$SINCE_DATE" --json number,title,author,createdAt,mergedAt,state --limit 200
```

Flag PRs where `mergedAt - createdAt > 3 days` or where state is still `open` and `createdAt` is more than 3 days ago.

### 6b: Stalled issues

Issues assigned during the sprint that saw no PR activity:

For each assigned open issue, check if any PR references it:

```bash
gh pr list --state all --search "\"#$ISSUE_NUM\"" --json number --limit 5
```

If no PRs reference it, the issue may be stalled.

### 6c: Blocker analysis

For flagged PRs and issues, identify likely causes:
- **Long review cycles:** PR had 3+ review rounds (from Step 5c data)
- **Dependency waits:** Issue body mentions "blocked by" another issue that's still open
- **No assignee:** Issue has been open but unassigned throughout the sprint
- **Scope creep:** PR had significantly more additions than typical (compare against sprint average)

## Step 7: Per-contributor breakdown

### 7a: Identify contributors

If Team section exists in pm-config.md, use those entries. Otherwise, derive from git activity:

```bash
# Unique authors of merged PRs in the period
gh pr list --state merged --search "merged:>=$SINCE_DATE" --json author --limit 200 | jq -r '.[].author.login' | sort -u
```

Exclude bot accounts (logins ending in `[bot]` or matching `dependabot`, `renovate`, `github-actions`).

### 7b: Per-contributor metrics

For each contributor, compute:

| Metric | Source |
|--------|--------|
| PRs merged | Count from Step 3a filtered by author |
| Code volume | Sum of additions + deletions from their merged PRs |
| Issues closed | Count from Step 3b filtered by closer |
| Avg review cycles | Mean cycles across their merged PRs |
| PRs reviewed | Count of reviews given on others' PRs (exclude self-reviews) |

For review participation:

```bash
# Server-side filter: only PRs updated during the review period
gh pr list --search "updated:>=$SINCE_DATE" --state all --limit 200 --json number --jq '.[].number' | while read -r pr_num; do
  gh api "repos/{owner}/{repo}/pulls/$pr_num/reviews?per_page=100" \
    --jq '.[] | select(.submitted_at > "'"$SINCE_ISO"'") | select(.user.login | (endswith("[bot]") or . == "github-actions") | not) | {reviewer: .user.login, pr: '"$pr_num"'}'
done
```

### 7c: Qualitative observations

For each contributor, identify constructive patterns:
- "Alice merged 5 PRs with an average of 0.8 review cycles — consistently clean code"
- "Bob reviewed 8 of the team's 12 PRs — primary reviewer this sprint"
- Frame positively — never negatively. If a contributor had low volume, show their metrics without commentary.

## Step 8: Lessons learned

Synthesize patterns from the sprint data:

### 8a: What went well

- Highlight contributors or areas with high throughput and low cycle times
- Note successful parallel execution (multiple PRs merged without conflicts)
- Flag any velocity improvements compared to typical patterns

### 8b: What slowed things down

- Long review cycles on specific PRs (and why — scope, complexity, reviewer availability)
- Dependency bottlenecks (issues that blocked multiple others)
- Stale issues that never got picked up

### 8c: Recommendations

Based on the data, suggest 2-3 actionable improvements:
- "Consider breaking large PRs into smaller ones — PRs over 500 lines averaged 2.5x longer cycle time"
- "3 issues are blocked by #42 — prioritize unblocking it next sprint"
- "No one reviewed frontend PRs — consider adding a frontend reviewer to the team"

## Step 9: Output the retrospective

### Header

```
# Sprint Review — {start date} to {end date} ({DAYS} days)
Repo: {repo name}
```

### Summary dashboard

```
## Summary

| Metric | Value |
|--------|-------|
| PRs merged | {count} (+{adds} / -{dels}) |
| Issues closed | {count} |
| Issues opened | {count} (net: {closed - opened}) |
| Avg cycle time | {duration} |
| Avg review cycles | {N} per PR |
| Issues slipped | {count} |
```

### What got done

```
## Completed Work

### Merged PRs ({count})
- **PR #{N} — {title}** (by @author, merged {date}) — {1-line summary}
- ...

### Closed Issues ({count})
- **#{N} — {title}** (closed by @author)
- ...
```

### What slipped

```
## Slipped Issues ({count})

Issues open at sprint start that are still open:
- **#{N} — {title}** — {reason: no assignee / blocked by #M / partially addressed in PR #K}
- ...
```

If no issues slipped, celebrate: "All sprint-start issues were resolved — clean sprint."

### Blockers

```
## Blockers Encountered

- **PR #{N} — {title}** — {blocker description: 4 review cycles, scope grew 3x}
- **Issue #{N} — {title}** — {blocker: blocked by #M which is still open}
```

If no blockers, note: "No significant blockers this sprint."

### Per-contributor breakdown

For each contributor (sorted alphabetically):

```
## Contributors

### {Display Name} (@username) — {Role if known}

| Metric | Value |
|--------|-------|
| PRs merged | {count} (+{adds} / -{dels}) |
| Issues closed | {count} |
| Avg review cycles | {N} |
| PRs reviewed | {count} |

**Observations:** {1-2 constructive sentences}
```

### Lessons learned

```
## Lessons Learned

### What went well
- {observation with data}

### What slowed us down
- {observation with data}

### Recommendations for next sprint
1. {actionable suggestion}
2. {actionable suggestion}
```

## Writing rules

- **Constructive framing only.** Never frame metrics negatively. "Low PR count" → omit or reframe as "focused on fewer, larger changes."
- **Data-driven observations.** Every claim in "Lessons Learned" must reference specific numbers from the sprint data. No vague assertions.
- **Handle single-contributor repos.** If only one contributor is found, use "Contribution Review" instead of team framing. Skip per-contributor breakdown (show metrics inline in the summary).
- **Handle empty sprints.** If no PRs were merged and no issues were closed, output: "No completed work found in the last {DAYS} days. This may indicate the sprint hasn't started yet, or work is in progress. Check open PRs for active work." Then stop.
- **Handle empty backlogs.** If no open issues exist for slippage analysis, note: "No pre-existing issues to evaluate for slippage."
- **Do not fabricate data.** If a metric cannot be computed from available GitHub data, omit it. Never estimate or extrapolate.
- **Keep the report scannable.** Tables for metrics, prose for observations. Total output should be readable in under 5 minutes.
- **Cycle time in human-readable format.** Display as "2d 4h" not "52 hours" or raw timestamps.
