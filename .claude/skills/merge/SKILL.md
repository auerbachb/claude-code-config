---
name: merge
description: Squash merge the current PR, delete the branch, log to work-log, and clean up. Verifies merge gate and acceptance criteria before merging.
---

Squash merge the current PR. This is the "we're done here" command.

## Steps

### Step 1: Identify the PR

```bash
gh pr view --json number,title,headRefName,body,state --jq '{number, title, headRefName, body, state}'
```

If no PR exists on the current branch, stop and tell the user: "No PR found for the current branch. Push and create a PR first."

If the PR is already merged or closed, stop and tell the user.

**Worktree check:** If running inside a git worktree where the feature branch is checked out, `git branch -D` will fail even after checking out away — git refuses to delete a branch checked out in any worktree. Detect this and abort early:

```bash
if [ "$(git rev-parse --git-common-dir)" != "$(git rev-parse --git-dir)" ]; then
  echo "Running inside a worktree. Use /wrap instead — it handles worktree removal before branch cleanup."
  exit 1
fi
```

If running in a worktree, stop here and tell the user: "This PR was developed in a worktree. Use `/wrap` instead of `/merge` — it removes the worktree first, then deletes the branch in the correct order."

### Step 2: Verify the merge gate

Determine which reviewer owns this PR:

1. **Check session-state** — read `~/.claude/session-state.json` and check the `reviewer` field for this PR number. If it says `"g"`, this PR is on Greptile.
2. **If no session-state entry**, check the PR's review history to determine ownership:
   ```bash
   gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" --jq '.[].user.login'
   gh api "repos/{owner}/{repo}/pulls/{N}/comments?per_page=100" --jq '.[].user.login'
   gh api "repos/{owner}/{repo}/issues/{N}/comments?per_page=100" --jq '.[].user.login'
   ```
   - If `greptile-apps[bot]` has posted reviews/comments, this PR is on Greptile.
   - Otherwise, it's on CR.

**Merge gate check:**

- **CR-only PR:** Need 2 clean CR reviews. Check the last 2 review objects from `coderabbitai[bot]` — both must have no actionable findings. Also verify the CodeRabbit check-run shows `conclusion: "success"`.
- **Greptile PR:** Need 1 clean Greptile review. Check the last review from `greptile-apps[bot]` has no actionable findings.

If the merge gate is NOT met, stop and tell the user exactly what's missing (e.g., "PR needs 1 more clean CR review" or "Greptile has unresolved findings").

### Step 3: Verify acceptance criteria

Run the `/check-acceptance-criteria` skill logic for this PR. All Test Plan checkboxes must be checked off before proceeding. If any fail, stop and report — do NOT merge with unchecked boxes.

### Step 4: Verify CI passes (NON-NEGOTIABLE)

Before merging, check ALL CI check-runs on the HEAD commit:

```bash
SHA=$(gh pr view <PR_NUMBER> --json commits --jq '.commits[-1].oid')
gh api "repos/{owner}/{repo}/commits/$SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "action_required") | {name, conclusion}'
```

**If ANY check-run has a blocking conclusion: DO NOT MERGE.** Instead:
1. Read the failure output: `gh api "repos/{owner}/{repo}/check-runs/{CHECK_RUN_ID}" --jq '.output.summary'`
2. Fix the issue (lint errors, type errors, test failures, etc.)
3. Commit, push, and wait for CI to re-run
4. Re-verify all checks pass before proceeding

**Never add `eslint-disable`, `@ts-ignore`, `@ts-expect-error`, or any suppression comment to work around CI.** Fix the actual code.

If all checks pass, proceed to merge.

### Step 5: Squash merge

```bash
gh pr merge --squash
```

Do NOT use `--delete-branch`. That flag attempts local branch deletion immediately, which fails when run from a worktree (the branch is still checked out). Handle branch cleanup in Step 5a below.

### Step 5a: Delete the branches

```bash
BRANCH_NAME=$(gh pr view --json headRefName --jq '.headRefName')
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
```

**Local branch** — must use `-D` (force), not `-d`. Squash merges rewrite history so the branch commits are not reachable from `main` and `-d` always fails post-squash.

If currently on the feature branch, check out the base branch first (can't delete the branch you're on):

```bash
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "$BRANCH_NAME" ]; then
  git checkout "$BASE_BRANCH"
fi
git branch -D "$BRANCH_NAME" || echo "Warning: local branch deletion failed (may already be deleted) — skipping"
```

**Remote branch** — treat failure as non-fatal (branch may already be deleted by GitHub's auto-delete-on-merge, by `/wrap` if run previously, or due to permissions/network):

```bash
git push origin --delete "$BRANCH_NAME" || echo "Warning: remote branch deletion failed (may already be deleted) — skipping"
```

### Step 5b: Sync local main

After merging, update the local `main` so subsequent sessions branch from the latest code. **Capture the result for the completion report in Step 7.**

```bash
MAIN_SYNC_STATUS=""

# Guard: uncommitted changes would block checkout
if [ -n "$(git status --porcelain)" ]; then
  MAIN_SYNC_STATUS="skipped: working tree has uncommitted changes — run manually: git checkout main && git pull origin main --ff-only"
fi

# Ensure we're on main before pulling
CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$MAIN_SYNC_STATUS" ] && [ "$CURRENT_BRANCH" != "main" ]; then
  if ! CHECKOUT_OUTPUT=$(git checkout main 2>&1); then
    MAIN_SYNC_STATUS="failed: could not checkout main — $CHECKOUT_OUTPUT"
  fi
fi

if [ -z "$MAIN_SYNC_STATUS" ]; then
  BEFORE_SHA=$(git rev-parse HEAD 2>/dev/null)
  if PULL_OUTPUT=$(git pull origin main --ff-only 2>&1); then
    AFTER_SHA=$(git rev-parse HEAD 2>/dev/null)
    if [ "$BEFORE_SHA" = "$AFTER_SHA" ]; then
      MAIN_SYNC_STATUS="up to date (${AFTER_SHA:0:7})"
    else
      MAIN_SYNC_STATUS="updated ${BEFORE_SHA:0:7} → ${AFTER_SHA:0:7}"
    fi
  else
    MAIN_SYNC_STATUS="failed: $PULL_OUTPUT"
  fi
fi

echo "Main sync: $MAIN_SYNC_STATUS"
```

Note: `/merge` only runs outside worktrees (Step 1 aborts in worktrees), so we should be on `main` after Step 5a's checkout. The explicit checkout-main guard handles edge cases. The `post-merge-pull.sh` hook also fires as a safety net, but this explicit step captures the result for reporting.

### Step 6: Log to work-log

If a work-log directory exists (detected at session start per work-log.md rules):

1. Determine the cycle count by reconstructing from PR history:
   ```bash
   # Fetch reviews and commits
   gh api "repos/{owner}/{repo}/pulls/{N}/reviews?per_page=100" \
     --jq '[.[] | select(.user.login == "coderabbitai[bot]" or .user.login == "greptile-apps[bot]") | {state, submitted_at}]'
   gh api "repos/{owner}/{repo}/pulls/{N}/commits?per_page=100" \
     --jq '[.[] | {sha: .sha, date: .commit.committer.date}]'
   ```
   - For each review where `state == "CHANGES_REQUESTED"` (or has inline comments with actionable findings), check if any commit has `committed_date > review.submitted_at`
   - If yes, that review-then-fix pair = 1 cycle. Multiple commits after a single review count as 1 cycle.
   - Include reviews from both `coderabbitai[bot]` and `greptile-apps[bot]`
   - Clean passes and confirmation reviews do not count
2. Append a merge entry to today's session log:
   ```
   - {time} ET — PR #{N} merged (Issue #{M}): {1-line summary} [opened: {open_time}, merged: {merge_time}, cycles: {count}]
   ```
3. Get the linked issue number from the PR body (`Closes #N` pattern)

### Step 7: Report completion

Tell the user:
- PR number and title
- Merge SHA
- Main branch {MAIN_SYNC_STATUS from Step 5b — e.g. "updated abc1234 → def5678", "up to date (abc1234)", or "failed: ..."}
- Branch deleted
- Work-log updated (if applicable)
