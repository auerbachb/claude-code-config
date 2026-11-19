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

Planning a batch? Claim the whole batch up front with the sibling in the same folder, `issue-claim-batch.sh`: `"$(dirname "$CLAIM")/issue-claim-batch.sh" --claim N N N --provider <...> --device <...>` prints one JSON line per issue. Work only the issues that come back `mine`; drop the rest from your plan, naming the holder. `--release N` drops an issue you will not do. `--check` is only a planning screen (it reads the `in-progress` label index, so a claim whose label was lost can look free, and a missing or closed issue comes back `unknown`); only `--claim` is authoritative. No batch helper next to `issue-claim.sh`? Claim each issue one at a time with `issue-claim.sh`. Keep each claim's `holder` from the JSON and pass it as `--holder` when you renew or release.

No helper installed (for example a cloud sandbox)? Use plain `gh`. This writes the same claim, and the helper reads it:

```bash
ME=$(gh api user --jq .login); HOLDER="<agent>-$(date +%s)-$$-$RANDOM"; NOW=$(date -u +%FT%TZ)   # no login? STOP.
gh issue view N --json state,labels,assignees,comments   # go on ONLY if this read succeeds, state is OPEN and nobody else holds it. Closed, missing, unreadable, claimed by someone else? STOP: nothing written yet.
gh label create in-progress 2>/dev/null || true
gh issue edit N --add-label in-progress --add-assignee @me
gh api repos/{owner}/{repo}/issues/N/comments -f body="🔒 Claimed by \`$ME\` for active work. Held by <agent> on device <nickname>. It will be released when this issue's PR merges or when the issue closes; it becomes stale if not renewed within 4h.

<!-- claude-claim: {\"holder\":\"$HOLDER\",\"login\":\"$ME\",\"since\":\"$NOW\",\"provider\":\"<agent>\",\"device\":\"<nickname>\"} -->"
gh api --paginate repos/{owner}/{repo}/issues/N/comments --jq '.[] | [.id, .created_at, .body] | @tsv'   # re-read every page: an earlier live claim by another holder (equal times: lower id wins)? Delete your own comment (keep its id from the POST) and STOP. Unreadable? Same.
# Release: delete every claim comment you posted for this holder (a refreshed claim leaves two), then:
gh issue edit N --remove-label in-progress --remove-assignee @me
```

A fallback claim has no in-place renewal: each claim comment expires 4 hours after it is posted, and a newer one from the same holder restarts that clock. If you are still working, first re-read the issue and its comments: if it is closed, someone else's claim is newer, or the read fails, STOP; otherwise post a fresh claim comment. The state screen cannot stop the issue closing after you read it: if it closes while you work, release the claim.

Working across worktrees? A claim made with the default holder belongs to the checkout it was made in, so a later `gh pr create` from another worktree can be blocked by your own claim. Claim with an explicit `--holder` before you create the worktree and keep that holder. Run the claim as its own command, never in the same command as `git worktree add`, `git checkout -b` or `gh pr create`: the guard checks the whole command before any of it runs. If the guard says your own claim may not be visible from this checkout, rerun the command with the `export CLAUDE_CLAIM_HOLDER='...' && ` prefix it prints, but only if you made that claim. Never copy a holder from the GitHub marker.

Opening a PR for a claimed issue? Put a hidden line in the PR body so the PR-side check can match it to the claim: `<!-- claim-holder: h-<12 hex> -->`. The value is the first 12 hex characters of the SHA-256 of your raw holder token, prefixed `h-`. Compute it with `printf '%s' "$HOLDER" | shasum -a 256 | cut -c1-12` (or `sha256sum`) and write `h-` in front of the result. A holder already shaped `h-<12 hex>` is used unchanged. Never paste the raw token, since it can carry a hostname or a path. `.claude/scripts/pr-claim-line.sh <N> --holder "$HOLDER"` prints the finished line.
<!-- END agent-issue-claims -->
