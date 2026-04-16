---
name: status
description: Show a dashboard of all open PRs with review state, unresolved findings, and blockers.
triggers:
  - show PRs
  - PR dashboard
  - what's open
  - review status
model: sonnet
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - WebFetch
  - WebSearch
---

Build a status dashboard of all open PRs in this repo.

## Steps

### Step 1: List open PRs

```bash
gh pr list --state open --json number,title,headRefName,updatedAt,author,additions,deletions --limit 50
```

If no open PRs, say "No open PRs." and stop.

### Step 2: For each PR, gather review state

For each open PR, run the shared PR-state helper once per PR. One invocation returns reviews, inline comments, issue comments, unresolved threads, check-runs, and bot status rollups — all derived from the same HEAD SHA:

```bash
STATE=$(.claude/scripts/pr-state.sh --pr "$N")
```

All subsequent queries read from `$STATE`:

```bash
# Last review from CR, BugBot, or Greptile (state: APPROVED / COMMENTED / CHANGES_REQUESTED)
jq '[.comments.reviews[]
     | select(.user.login == "coderabbitai[bot]" or .user.login == "cursor[bot]" or .user.login == "greptile-apps[bot]")
     | {user: .user.login, state, submitted: .submitted_at}]
     | sort_by(.submitted) | if length == 0 then {} else last end' "$STATE"

# Unresolved thread count
jq '.threads.unresolved_count' "$STATE"

# CR/BugBot/Greptile issue-comment count (summaries, acks, PR-level findings)
jq '[.comments.conversation[]
     | select(.user.login == "coderabbitai[bot]" or .user.login == "cursor[bot]" or .user.login == "greptile-apps[bot]")]
     | length' "$STATE"

# CodeRabbit check-run status (also serves as rate-limit signal via title).
# Falls back to the commit-status rollup for repos that report CR via the legacy statuses API.
CR_CHECK=$(jq '.check_runs.all[] | select(.name == "CodeRabbit") | {status, conclusion, title}' "$STATE")
if [ -z "$CR_CHECK" ] || [ "$CR_CHECK" = "null" ]; then
  jq '.bot_statuses.CodeRabbit' "$STATE"    # legacy commit-status path
else
  echo "$CR_CHECK"
fi

# BugBot (Cursor) check-run — included so PRs on the BugBot path show review status
jq '.check_runs.all[] | select(.name == "Cursor Bugbot") | {name, status, conclusion}' "$STATE"
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
