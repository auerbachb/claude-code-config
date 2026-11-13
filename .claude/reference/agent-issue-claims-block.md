<!-- BEGIN agent-issue-claims (managed by repo-bootstrap.sh; source: .claude/reference/agent-issue-claims-block.md in claude-code-config) -->
## Issue claims (all coding agents)

This section takes precedence over any other guidance in this file for **claiming issues only**.

1. **Check** before you start an issue: is it already claimed?
2. **Claim** it if it is free, and say who you are (agent name and machine nickname).
3. If it is `claimed`, or you **cannot tell**, leave it alone and name the holder.
4. **Release** it when you finish or give up.

Helper (first one that exists): `~/.claude/skills-worktree/.claude/scripts/issue-claim.sh`, `~/.claude/scripts/issue-claim.sh`, `.claude/scripts/issue-claim.sh`.

```bash
CLAIM=<the helper path>
"$CLAIM" N --check      # mine / free / stale: go on. claimed / unknown: STOP.
"$CLAIM" N --claim --provider <codex|cursor|antigravity|...> --device <machine nickname>
"$CLAIM" N --renew      # long work: at each phase change and before waiting on review or CI
"$CLAIM" N --release    # on merge, close or abandon
```

No helper installed (for example a cloud sandbox)? Use plain `gh`. This writes the same claim, and the helper reads it:

```bash
ME=$(gh api user --jq .login); HOLDER="<agent>-$(date +%s)-$$-$RANDOM"; NOW=$(date -u +%FT%TZ)
gh label create in-progress 2>/dev/null || true
gh issue view N --json labels,assignees,comments   # claimed by someone else, or unreadable? STOP.
gh issue edit N --add-label in-progress --add-assignee @me
gh api repos/{owner}/{repo}/issues/N/comments -f body="🔒 Claimed by \`$ME\` for active work. Held by <agent> on device <nickname>. It will be released when this issue's PR merges or when the issue closes; it becomes stale if not renewed within 4h.

<!-- claude-claim: {\"holder\":\"$HOLDER\",\"login\":\"$ME\",\"since\":\"$NOW\",\"provider\":\"<agent>\",\"device\":\"<nickname>\"} -->"
gh api --paginate repos/{owner}/{repo}/issues/N/comments --jq '.[] | [.id, .created_at, .body] | @tsv'   # re-read every page: an earlier live claim by another holder (equal times: lower id wins)? Delete your own comment (keep its id from the POST) and STOP. Unreadable? Same.
# Release: delete your claim comment, then:
gh issue edit N --remove-label in-progress --remove-assignee @me
```

A fallback claim cannot be renewed; it expires after 4 hours without a renewal. If you are still working, post a fresh claim comment.
<!-- END agent-issue-claims -->
