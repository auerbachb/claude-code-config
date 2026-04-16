---
name: pm-team-standup
description: Summarize what each contributor did in the past 24 hours — commits, PRs, issues, and reviews grouped by person. Multi-contributor version of /standup. Uses Team section from pm-config.md for display names and roles when available.
argument-hint: "[since-time, e.g. \"yesterday at noon ET\"]"
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - WebFetch
  - WebSearch
---

## Data gathering

This skill uses the canonical query patterns documented in `.claude/reference/pm-data-patterns.md` (time windows, review participation, bot filtering). When updating data collection logic, update the reference doc AND any skills that depend on it.

Generate a team standup report showing what each contributor accomplished since $ARGUMENTS (default: "yesterday at noon ET" if no argument given).

## Step 1: Set time range

Convert the user's time reference to an ISO 8601 timestamp and a `git log`-compatible `--since` value:

```bash
# ISO 8601 "yesterday at noon ET" with colon offset (GitHub search requires +HH:MM not +HHMM).
# This skill uses noon-anchored lookback — not midnight — so we keep this inline rather
# than using .claude/scripts/gh-window.sh (which anchors to midnight).
SINCE_ISO=$(TZ='America/New_York' date -v-1d -v12H -v0M -v0S '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || TZ='America/New_York' date -d 'yesterday 12:00' '+%Y-%m-%dT%H:%M:%S%z')
SINCE_ISO=$(printf '%s' "$SINCE_ISO" | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')

# Date for GitHub search (YYYY-MM-DD)
SINCE_DATE=$(bash .claude/scripts/gh-window.sh --days 1 --format date)
```

Adjust the date expressions to match the user's time reference. See `.claude/scripts/gh-window.sh` for the date-window builder (used above for `$SINCE_DATE`; `$SINCE_ISO` stays inline because this skill anchors to noon, not midnight).

## Step 2: Load team config (optional)

Check if `.claude/pm-config.md` exists and has a `## Team` section:

```bash
test -f .claude/pm-config.md && echo "CONFIG_EXISTS" || echo "NO_CONFIG"
```

If the config exists, parse the `## Team` section (line-anchored `^## Team` through the next `^## ` header or EOF). Extract any contributor entries — typically formatted as:

```
- @github-username — Display Name (Role)
```

Build a lookup map of GitHub username → display name and role. If no Team section exists or it contains only placeholder text, skip this step — use GitHub usernames as-is.

## Step 3: Gather activity data

### 3a: Commits by author

```bash
git log --since="$SINCE_ISO" --format='%aN|||%aE|||%s' --no-merges
```

Group commits by author name. For each author, collect commit messages.

### 3b: PRs opened, merged, or updated

```bash
# PRs updated in the time range (paginate to capture all activity)
gh api --paginate "repos/{owner}/{repo}/pulls?state=all&sort=updated&direction=desc&per_page=100" \
  | jq '[.[] | select(.updated_at > "'"$SINCE_ISO"'") | {number, title, author: .user, state, mergedAt: .merged_at, createdAt: .created_at, additions, deletions}]'
```

For each PR, categorize:
- **Opened:** `createdAt` is after the cutoff
- **Merged:** `mergedAt` is after the cutoff
- **Updated:** was updated but not opened or merged in the window (likely reviewed or pushed to)

Group PRs by `author.login`.

### 3c: Issues created or closed

```bash
# Issues created
gh issue list --state all --search "created:>=$SINCE_DATE" --json number,title,author,state,createdAt --limit 500

# Issues closed
gh issue list --state closed --search "closed:>=$SINCE_DATE" --json number,title,closedAt --limit 500
```

Group by author for created issues. Closed issues may not have an easy author attribution — note them separately if the closer isn't identifiable.

### 3d: PR review comments authored

```bash
# Fetch reviews from all PRs active in the standup window (paginate to capture all)
gh api --paginate "repos/{owner}/{repo}/pulls?state=all&sort=updated&direction=desc&per_page=100" \
  | jq -r '.[] | select(.updated_at > "'"$SINCE_ISO"'") | .number' | while read -r pr_num; do
  gh api "repos/{owner}/{repo}/pulls/$pr_num/reviews?per_page=100" \
    --jq '.[] | select(.submitted_at > "'"$SINCE_ISO"'") | {user: .user.login, pr: '"$pr_num"', state: .state}'
done
```

Group reviews by reviewer username. If this is too slow for very large repos, fall back to just listing merged/opened PRs without review data.

## Step 4: Filter out bots

Exclude known bot accounts from the contributor list:
- Usernames ending in `[bot]` (e.g., `dependabot[bot]`, `coderabbitai[bot]`, `greptile-apps[bot]`)
- Usernames matching common bot patterns: `dependabot`, `renovate`, `github-actions`

## Step 5: Build per-contributor sections

For each human contributor found in Steps 3a-3d:

1. **Resolve display name:** If the Team section lookup (Step 2) has an entry for this GitHub username, use the display name and role. Otherwise, use the GitHub username.
2. **Merge all activity** for this person across all data sources.

### Single-contributor handling

If only one contributor is found, still output the report — just show their activity without the multi-person framing. Lead with "Here's what was accomplished" instead of "Here's what the team accomplished."

## Step 6: Read PR bodies for context (CRITICAL — do not skip)

For every PR that was merged or opened in the window, read the PR body to extract business context:

```bash
gh pr view $PR_NUMBER --json body,title,additions,deletions
```

Scan each PR body for what the change enables — the "so what" for the project. Use this context in the activity bullets.

## Step 7: Write the report

### Header

```
# Team Standup — {date}
Since {time reference}
```

### Per-contributor sections

For each contributor (sorted by volume of activity, most active first):

```
## {Display Name} (@username) — {Role if known}

- **PRs merged:** #N — {title} (+adds/-dels) — {1-line business context from PR body}
- **PRs opened:** #M — {title}
- **Issues created:** #K — {title}
- **Issues closed:** #J — {title}
- **Reviews given:** Reviewed PR #X, PR #Y
- **Commits:** {count} commits — {summary of themes if >3 commits, or list if ≤3}
```

Omit any activity category that has zero items for a contributor. Do not pad with "no activity" lines.

### Closing summary

End with a 1-2 sentence synthesis: "The team's combined output was X PRs merged, Y issues closed, and Z reviews completed. Key themes: {brief list of what advanced}."

## Writing rules

- Frame activity in terms of **what it accomplished**, not just "merged PR #42" — include the business context from the PR body
- Keep each bullet to 1 line — this is a standup, not a detailed report
- Sort contributors by activity volume (most active first)
- If a contributor had no activity in the window, omit them entirely — do not list them with "no activity"
- Do NOT mention CR review cycles, code review tooling details, or process internals
- Do NOT pad with filler — if the window was quiet, say so briefly
- Use display names from Team config when available, GitHub usernames as fallback
