---
name: status
description: Show a dashboard of all open PRs with review state, unresolved findings, and blockers.
---

Build a status dashboard of all open PRs in this repo.

## Steps

### Step 1: List open PRs

```bash
gh pr list --state open --json number,title,headRefName,updatedAt,author,additions,deletions --limit 50
```

If no open PRs, say "No open PRs." and stop.

### Step 2: For each PR, gather review state

For each open PR, fetch review data from all 3 endpoints:

```bash
# Reviews (approve/changes requested)
gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]") | {user: .user.login, state: .state, submitted: .submitted_at}] | sort_by(.submitted) | if length == 0 then {} else last end'

# Unresolved findings (use GraphQL to get only unresolved threads)
gh api graphql -f query='query { repository(owner: "{owner}", name: "{repo}") { pullRequest(number: {N}) { reviewThreads(first: 100) { nodes { isResolved comments(first: 1) { nodes { author { login } } } } } } } }' \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length'

# Issue comments (summary, ack)
gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" \
  --jq '[.[] | select(.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]")] | length'
```

Also check the commit status:
```bash
SHA=$(gh pr view N --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name == "CodeRabbit") | {status: .status, conclusion: .conclusion}'
```

### Step 3: Determine status for each PR

Classify each PR into one of these states:
- **Clean (merge-ready)** — merge gate satisfied (2 clean CR or 1 clean G)
- **Has findings** — reviewer posted actionable comments that need fixing
- **Review pending** — pushed but no review yet
- **Rate-limited** — CR check shows rate limit failure

Also note:
- Which reviewer owns the PR (CR or Greptile)
- Number of unresolved inline comments
- Time since last update

### Step 4: Check session-state

If `~/.claude/session-state.json` exists, cross-reference it:
- Active agents and what they're doing
- Phase assignments (A/B/C)
- CR quota usage this hour

### Step 5: Format the dashboard

Output a table like:

```
PR    | Title                          | Reviewer | State          | Findings | HEAD SHA | Updated
------|--------------------------------|----------|----------------|----------|----------|--------
#40   | Add slash commands             | CR       | Review pending | 0        | 517690c  | 2 min ago
#38   | Fix auth middleware            | Greptile | Has findings   | 3        | d0e4fef  | 15 min ago
#35   | Add post-merge hook            | CR       | Clean          | 0        | 7b2cfbf  | 1 hr ago
```

Below the table, add:
- **Blocked:** List any PRs that are blocked and why
- **CR quota:** N/8 reviews used this hour (if session-state available)
- **Active agents:** List any running agents and their tasks (if session-state available)
